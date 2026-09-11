-- =====================================================================
--  ВОПРОС 8. Повторные покупки и ранняя диагностика оттока
--
--  Бизнес-вопрос: где рвётся цепочка повторных покупок, сколько времени
--  есть на реактивацию и кого нужно догонять прямо сейчас?
--
--  Зависимости: sql/00_setup_views.sql
--
--  Здесь всё держится на двух оконных функциях:
--    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_ts)
--        — порядковый номер заказа В ЖИЗНИ клиента;
--    LAG(order_ts) OVER (тот же кадр)
--        — дата предыдущего заказа, чтобы получить интервал между
--          покупками без соединения таблицы заказов с самой собой.
--
--  Определение оттока. Фиксированный порог («не покупал 180 дней»)
--  плох тем, что клиент с циклом в 2 месяца и клиент с циклом в год
--  считаются одинаково. В блоке D порог ПЕРСОНАЛЬНЫЙ: клиент под
--  угрозой, если молчит дольше, чем два его собственных средних
--  интервала между покупками.
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Где рвётся цепочка: переход от заказа N к заказу N+1 ==="
.print ""

WITH seq AS (
    SELECT
        customer_id,
        order_id,
        ROW_NUMBER() OVER (PARTITION BY customer_id
                           ORDER BY order_ts, order_id) AS order_no
    FROM v_orders_enriched
),
counts AS (
    SELECT order_no, COUNT(DISTINCT customer_id) AS customers
    FROM seq GROUP BY order_no
)
SELECT
    order_no                                                              AS nth_order,
    customers,
    -- доля дошедших сюда от ВСЕЙ базы
    ROUND(100.0 * customers
          / FIRST_VALUE(customers) OVER (ORDER BY order_no), 1)           AS pct_of_all_customers,
    -- вероятность сделать следующий заказ, если уже сделал этот
    ROUND(100.0 * customers / LAG(customers) OVER (ORDER BY order_no), 1) AS progression_pct,
    LAG(customers) OVER (ORDER BY order_no) - customers                   AS lost_here
FROM counts
WHERE order_no <= 8
ORDER BY order_no;


.print ""
.print "=== B. Интервал между покупками: сокращается с каждым заказом ==="
.print "    Медиана и p90 считаются через CUME_DIST (в SQLite нет PERCENTILE)"
.print ""

WITH seq AS (
    SELECT
        customer_id,
        order_ts,
        ROW_NUMBER() OVER w AS order_no,
        LAG(order_ts) OVER w AS prev_order_ts
    FROM v_orders_enriched
    WINDOW w AS (PARTITION BY customer_id ORDER BY order_ts, order_id)
),
gaps AS (
    SELECT
        order_no,
        CAST(julianday(order_ts) - julianday(prev_order_ts) AS INTEGER) AS gap_days
    FROM seq
    WHERE prev_order_ts IS NOT NULL
),
ranked AS (
    SELECT order_no, gap_days,
           CUME_DIST() OVER (PARTITION BY order_no ORDER BY gap_days) AS cd
    FROM gaps
)
SELECT
    (order_no - 1) || ' -> ' || order_no                AS transition,
    COUNT(*)                                            AS observations,
    ROUND(AVG(gap_days))                                AS avg_days,
    MIN(CASE WHEN cd >= 0.5 THEN gap_days END)          AS median_days,
    MIN(CASE WHEN cd >= 0.9 THEN gap_days END)          AS p90_days
FROM ranked
WHERE order_no <= 6
GROUP BY order_no
ORDER BY order_no;


.print ""
.print "=== C. Окно для реактивации: когда происходит второй заказ ==="
.print ""

WITH seq AS (
    SELECT customer_id, order_ts,
           ROW_NUMBER() OVER w AS order_no,
           LAG(order_ts) OVER w AS prev_order_ts
    FROM v_orders_enriched
    WINDOW w AS (PARTITION BY customer_id ORDER BY order_ts, order_id)
),
second_orders AS (
    SELECT CAST(julianday(order_ts) - julianday(prev_order_ts) AS INTEGER) AS gap_days
    FROM seq WHERE order_no = 2
),
bucketed AS (
    SELECT CASE
             WHEN gap_days <= 30  THEN '1. до 30 дней'
             WHEN gap_days <= 60  THEN '2. 31-60 дней'
             WHEN gap_days <= 90  THEN '3. 61-90 дней'
             WHEN gap_days <= 180 THEN '4. 91-180 дней'
             ELSE                      '5. свыше 180 дней'
           END AS bucket
    FROM second_orders
)
SELECT
    bucket,
    COUNT(*)                                                       AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)             AS pct,
    -- накопленным итогом: какая доля вторых заказов уже случилась
    ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY bucket)
          / SUM(COUNT(*)) OVER (), 1)                              AS cum_pct
FROM bucketed
GROUP BY bucket
ORDER BY bucket;


.print ""
.print "=== D. Под угрозой ПРЯМО СЕЙЧАС: персональный порог молчания ==="
.print "    Клиент с 3+ заказами, молчащий дольше двух своих средних интервалов"
.print ""

WITH ref AS (SELECT MAX(order_ts) AS as_of FROM v_orders_enriched),
seq AS (
    SELECT customer_id, order_ts, order_revenue,
           ROW_NUMBER() OVER w AS order_no,
           LAG(order_ts) OVER w AS prev_order_ts
    FROM v_orders_enriched
    WINDOW w AS (PARTITION BY customer_id ORDER BY order_ts, order_id)
),
per_customer AS (
    SELECT
        customer_id,
        COUNT(*)                                                   AS orders,
        SUM(order_revenue)                                         AS lifetime_revenue,
        MAX(order_ts)                                              AS last_order_ts,
        AVG(CAST(julianday(order_ts) - julianday(prev_order_ts) AS INTEGER)) AS avg_gap_days
    FROM seq
    GROUP BY customer_id
    HAVING COUNT(*) >= 3
),
scored AS (
    SELECT
        pc.*,
        CAST(julianday((SELECT as_of FROM ref)) - julianday(pc.last_order_ts) AS INTEGER) AS days_silent,
        pc.avg_gap_days * 2 AS personal_threshold
    FROM per_customer pc
)
SELECT
    CASE WHEN days_silent > personal_threshold THEN 'под угрозой'
         ELSE 'в норме' END                                          AS status,
    COUNT(*)                                                         AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)               AS pct,
    ROUND(AVG(avg_gap_days))                                         AS avg_personal_cycle_days,
    ROUND(AVG(days_silent))                                          AS avg_days_silent,
    ROUND(SUM(lifetime_revenue))                                     AS revenue_involved,
    ROUND(100.0 * SUM(lifetime_revenue) / SUM(SUM(lifetime_revenue)) OVER (), 1) AS pct_of_revenue
FROM scored
GROUP BY status
ORDER BY status;

.print ""
.print "    Топ-10 самых дорогих клиентов под угрозой (лист для обзвона):"
.print ""

WITH ref AS (SELECT MAX(order_ts) AS as_of FROM v_orders_enriched),
seq AS (
    SELECT customer_id, order_ts, order_revenue,
           LAG(order_ts) OVER w AS prev_order_ts
    FROM v_orders_enriched
    WINDOW w AS (PARTITION BY customer_id ORDER BY order_ts, order_id)
),
per_customer AS (
    SELECT customer_id, COUNT(*) AS orders, SUM(order_revenue) AS lifetime_revenue,
           MAX(order_ts) AS last_order_ts,
           AVG(CAST(julianday(order_ts) - julianday(prev_order_ts) AS INTEGER)) AS avg_gap_days
    FROM seq GROUP BY customer_id HAVING COUNT(*) >= 3
)
SELECT
    pc.customer_id,
    c.acquisition_channel                                                    AS channel,
    pc.orders,
    ROUND(pc.lifetime_revenue)                                               AS ltv_revenue,
    ROUND(pc.avg_gap_days)                                                   AS avg_cycle_days,
    CAST(julianday((SELECT as_of FROM ref)) - julianday(pc.last_order_ts) AS INTEGER) AS days_silent,
    substr(pc.last_order_ts, 1, 10)                                          AS last_order
FROM per_customer pc
JOIN customers c ON c.customer_id = pc.customer_id
WHERE CAST(julianday((SELECT as_of FROM ref)) - julianday(pc.last_order_ts) AS INTEGER)
      > pc.avg_gap_days * 2
ORDER BY pc.lifetime_revenue DESC
LIMIT 10;

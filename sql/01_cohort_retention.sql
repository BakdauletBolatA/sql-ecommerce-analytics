-- =====================================================================
--  ВОПРОС 1. Удержание клиентов по когортам привлечения
--
--  Бизнес-вопрос: мы растём за счёт того, что удерживаем клиентов, или
--  за счёт того, что покупаем новых взамен ушедших? Какие когорты
--  «здоровые», а какие рассыпаются в первый же месяц?
--
--  Зависимости: sql/00_setup_views.sql
--
--  Методические решения:
--   * Когорта = месяц ПЕРВОГО оплаченного заказа (v_customer_cohort).
--   * Клиент считается «удержанным» в месяце M, если сделал в нём хотя бы
--     один неотменённый заказ. Не «зашёл на сайт», а именно купил.
--   * ПРАВАЯ ЦЕНЗУРА: у августовской когорты 2026 года физически нет
--     данных за M+3. Такие ячейки должны быть NULL, а не 0 — иначе
--     средние по столбцу поедут вниз и свежие когорты будут выглядеть
--     провальными. Ниже это разделено явно.
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Треугольник удержания (% от размера когорты) ==="
.print "    NULL = месяц ещё не наступил (правая цензура), не ноль"
.print ""

WITH bounds AS (
    -- последний месяц, за который вообще есть данные
    SELECT MAX(CAST(strftime('%Y', order_ts) AS INTEGER) * 12
             + CAST(strftime('%m', order_ts) AS INTEGER)) AS last_idx
    FROM v_orders_enriched
),
activity AS (
    -- DISTINCT обязателен: два заказа в одном месяце — это один активный
    -- клиент, иначе retention может превысить 100%
    SELECT DISTINCT
        cc.cohort_month,
        cc.cohort_idx,
        o.customer_id,
        (CAST(strftime('%Y', o.order_ts) AS INTEGER) * 12
       + CAST(strftime('%m', o.order_ts) AS INTEGER)) - cc.cohort_idx AS month_offset
    FROM v_orders_enriched o
    JOIN v_customer_cohort cc ON cc.customer_id = o.customer_id
),
cohort_size AS (
    SELECT cohort_month, cohort_idx, COUNT(*) AS cohort_size
    FROM activity
    WHERE month_offset = 0
    GROUP BY cohort_month, cohort_idx
),
retention AS (
    SELECT
        a.cohort_month,
        a.month_offset,
        cs.cohort_idx,
        cs.cohort_size,
        ROUND(100.0 * COUNT(*) / cs.cohort_size, 1) AS retention_pct
    FROM activity a
    JOIN cohort_size cs ON cs.cohort_month = a.cohort_month
    GROUP BY a.cohort_month, a.month_offset
),
observed AS (
    SELECT r.*, b.last_idx - r.cohort_idx AS months_observed
    FROM retention r CROSS JOIN bounds b
)
SELECT
    cohort_month                                                       AS cohort,
    MAX(cohort_size)                                                   AS size,
    -- Наблюдаемая ячейка без покупок = честный 0; ненаблюдаемая = NULL
    CASE WHEN MAX(months_observed) >= 1 THEN
        COALESCE(MAX(CASE WHEN month_offset = 1 THEN retention_pct END), 0) END AS m1,
    CASE WHEN MAX(months_observed) >= 2 THEN
        COALESCE(MAX(CASE WHEN month_offset = 2 THEN retention_pct END), 0) END AS m2,
    CASE WHEN MAX(months_observed) >= 3 THEN
        COALESCE(MAX(CASE WHEN month_offset = 3 THEN retention_pct END), 0) END AS m3,
    CASE WHEN MAX(months_observed) >= 6 THEN
        COALESCE(MAX(CASE WHEN month_offset = 6 THEN retention_pct END), 0) END AS m6,
    CASE WHEN MAX(months_observed) >= 9 THEN
        COALESCE(MAX(CASE WHEN month_offset = 9 THEN retention_pct END), 0) END AS m9,
    CASE WHEN MAX(months_observed) >= 12 THEN
        COALESCE(MAX(CASE WHEN month_offset = 12 THEN retention_pct END), 0) END AS m12
FROM observed
GROUP BY cohort_month
ORDER BY cohort_month;


.print ""
.print "=== B. Качество когорт: M1 против среднего (оконные функции) ==="
.print ""

WITH bounds AS (
    SELECT MAX(CAST(strftime('%Y', order_ts) AS INTEGER) * 12
             + CAST(strftime('%m', order_ts) AS INTEGER)) AS last_idx
    FROM v_orders_enriched
),
activity AS (
    SELECT DISTINCT
        cc.cohort_month, cc.cohort_idx, o.customer_id,
        (CAST(strftime('%Y', o.order_ts) AS INTEGER) * 12
       + CAST(strftime('%m', o.order_ts) AS INTEGER)) - cc.cohort_idx AS month_offset
    FROM v_orders_enriched o
    JOIN v_customer_cohort cc ON cc.customer_id = o.customer_id
),
cohort_m1 AS (
    SELECT
        a.cohort_month,
        a.cohort_idx,
        COUNT(DISTINCT CASE WHEN a.month_offset = 0 THEN a.customer_id END) AS cohort_size,
        ROUND(100.0 * COUNT(DISTINCT CASE WHEN a.month_offset = 1 THEN a.customer_id END)
                    / COUNT(DISTINCT CASE WHEN a.month_offset = 0 THEN a.customer_id END), 1) AS m1
    FROM activity a
    GROUP BY a.cohort_month, a.cohort_idx
    -- отбрасываем последнюю когорту: у неё месяц M+1 ещё не закончился
    HAVING a.cohort_idx < (SELECT last_idx FROM bounds)
)
SELECT
    cohort_month                                                        AS cohort,
    cohort_size                                                         AS size,
    m1                                                                  AS m1_pct,
    -- AVG(...) OVER () — среднее по ВСЕМ когортам без отдельного запроса
    ROUND(AVG(m1) OVER (), 1)                                           AS avg_all,
    ROUND(m1 - AVG(m1) OVER (), 1)                                      AS delta_vs_avg,
    -- скользящее среднее за 3 когорты: сглаживает шум маленьких когорт
    ROUND(AVG(m1) OVER (ORDER BY cohort_month
                        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1)   AS ma3,
    -- сравнение с предыдущей когортой
    ROUND(m1 - LAG(m1) OVER (ORDER BY cohort_month), 1)                 AS vs_prev,
    RANK()       OVER (ORDER BY m1 DESC)                                AS rank_m1,
    -- размер когорты и её качество — независимые вещи, показываем оба ранга
    RANK()       OVER (ORDER BY cohort_size DESC)                       AS rank_size
FROM cohort_m1
ORDER BY cohort_month;


.print ""
.print "=== C. Скидочные когорты (ноя/дек) против остальных ==="
.print "    Проверяем гипотезу: распродажа приводит МНОГО, но ПЛОХИХ клиентов"
.print ""

WITH activity AS (
    SELECT DISTINCT
        cc.cohort_month, cc.cohort_idx, o.customer_id,
        (CAST(strftime('%Y', o.order_ts) AS INTEGER) * 12
       + CAST(strftime('%m', o.order_ts) AS INTEGER)) - cc.cohort_idx AS month_offset
    FROM v_orders_enriched o
    JOIN v_customer_cohort cc ON cc.customer_id = o.customer_id
),
labelled AS (
    SELECT *,
           CASE WHEN CAST(substr(cohort_month, 6, 2) AS INTEGER) IN (11, 12)
                THEN 'promo (ноя-дек)' ELSE 'обычная' END AS cohort_type
    FROM activity
    -- берём только когорты, прожившие >= 3 месяцев, чтобы сравнение было честным
    WHERE cohort_idx <= (SELECT MAX(CAST(strftime('%Y', order_ts) AS INTEGER) * 12
                                  + CAST(strftime('%m', order_ts) AS INTEGER)) - 3
                         FROM v_orders_enriched)
),
per_cohort AS (
    SELECT cohort_month, cohort_type,
           COUNT(DISTINCT CASE WHEN month_offset = 0 THEN customer_id END) AS size,
           COUNT(DISTINCT CASE WHEN month_offset = 1 THEN customer_id END) AS a1,
           COUNT(DISTINCT CASE WHEN month_offset = 3 THEN customer_id END) AS a3
    FROM labelled
    GROUP BY cohort_month, cohort_type
)
SELECT
    cohort_type,
    COUNT(*)                                     AS n_cohorts,
    SUM(size)                                    AS customers,
    ROUND(AVG(size), 0)                          AS avg_cohort_size,
    ROUND(100.0 * SUM(a1) / SUM(size), 1)        AS m1_pct,
    ROUND(100.0 * SUM(a3) / SUM(size), 1)        AS m3_pct
FROM per_cohort
GROUP BY cohort_type;


.print ""
.print "=== D. Удержание по каналу привлечения ==="
.print ""

WITH activity AS (
    SELECT DISTINCT
        cc.acquisition_channel, cc.customer_id, cc.cohort_idx,
        (CAST(strftime('%Y', o.order_ts) AS INTEGER) * 12
       + CAST(strftime('%m', o.order_ts) AS INTEGER)) - cc.cohort_idx AS month_offset
    FROM v_orders_enriched o
    JOIN v_customer_cohort cc ON cc.customer_id = o.customer_id
    WHERE cc.cohort_idx <= (SELECT MAX(CAST(strftime('%Y', order_ts) AS INTEGER) * 12
                                     + CAST(strftime('%m', order_ts) AS INTEGER)) - 6
                            FROM v_orders_enriched)
),
by_channel AS (
    SELECT acquisition_channel,
           COUNT(DISTINCT CASE WHEN month_offset = 0 THEN customer_id END) AS cohort_size,
           COUNT(DISTINCT CASE WHEN month_offset = 1 THEN customer_id END) AS a1,
           COUNT(DISTINCT CASE WHEN month_offset = 3 THEN customer_id END) AS a3,
           COUNT(DISTINCT CASE WHEN month_offset = 6 THEN customer_id END) AS a6
    FROM activity
    GROUP BY acquisition_channel
)
SELECT
    acquisition_channel                                      AS channel,
    cohort_size                                              AS customers,
    ROUND(100.0 * a1 / cohort_size, 1)                       AS m1_pct,
    ROUND(100.0 * a3 / cohort_size, 1)                       AS m3_pct,
    ROUND(100.0 * a6 / cohort_size, 1)                       AS m6_pct,
    -- доля канала в общей клиентской базе: NTILE/SUM OVER без второго прохода
    ROUND(100.0 * cohort_size / SUM(cohort_size) OVER (), 1) AS share_of_base_pct,
    RANK() OVER (ORDER BY 1.0 * a3 / cohort_size DESC)       AS rank_by_m3
FROM by_channel
ORDER BY m3_pct DESC;

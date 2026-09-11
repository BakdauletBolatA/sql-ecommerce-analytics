-- =====================================================================
--  ВОПРОС 5. RFM-сегментация клиентской базы
--
--  Бизнес-вопрос: кого удерживать, кого реактивировать, а на кого не
--  тратить бюджет? Сколько денег стоит за каждым сегментом?
--
--  Зависимости: sql/00_setup_views.sql
--
--  R (Recency)   — дней с последней покупки, меньше = лучше
--  F (Frequency) — число оплаченных заказов за всю жизнь
--  M (Monetary)  — суммарная чистая выручка клиента
--
--  ГЛАВНОЕ МЕТОДИЧЕСКОЕ РЕШЕНИЕ (см. блок A):
--  По R и M квинтили считаются через NTILE(5) — там значения почти
--  непрерывные. По F NTILE(5) применять НЕЛЬЗЯ: 58% клиентов имеют ровно
--  один заказ, и NTILE, которому всё равно на равенство значений,
--  раскидает эту одну и ту же группу по трём разным квинтилям. Два
--  одинаковых клиента получили бы разный балл. Поэтому F размечается
--  явными порогами.
--
--  Точка отсчёта — последняя дата в данных, а не текущая дата: витрина
--  историческая, и CURRENT_DATE сделал бы отчёт «протухающим».
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Почему NTILE(5) по частоте здесь сломался бы ==="
.print "    Один и тот же клиент с 1 заказом попадает в разные квинтили"
.print ""

WITH scored AS (
    SELECT orders_lifetime,
           NTILE(5) OVER (ORDER BY orders_lifetime) AS f_ntile
    FROM v_customer_cohort
)
SELECT
    orders_lifetime                            AS orders,
    COUNT(*)                                   AS customers,
    MIN(f_ntile)                               AS min_ntile,
    MAX(f_ntile)                               AS max_ntile,
    CASE WHEN MIN(f_ntile) <> MAX(f_ntile)
         THEN 'РАЗОРВАН между квинтилями' ELSE 'ок' END AS verdict
FROM scored
GROUP BY orders_lifetime
ORDER BY orders_lifetime
LIMIT 6;


.print ""
.print "=== B. RFM-скоринг и распределение по сегментам ==="
.print ""

WITH ref AS (
    -- точка отсчёта = последний заказ в витрине
    SELECT MAX(order_ts) AS as_of FROM v_orders_enriched
),
base AS (
    SELECT
        c.customer_id,
        c.acquisition_channel,
        CAST(julianday((SELECT as_of FROM ref)) - julianday(MAX(o.order_ts)) AS INTEGER) AS recency_days,
        COUNT(DISTINCT o.order_id)  AS frequency,
        SUM(o.order_revenue)        AS monetary,
        SUM(o.order_contribution)   AS contribution
    FROM v_customer_cohort c
    JOIN v_orders_enriched o ON o.customer_id = c.customer_id
    GROUP BY c.customer_id, c.acquisition_channel
),
scored AS (
    SELECT
        base.*,
        -- R: чем СВЕЖЕЕ покупка, тем выше балл -> сортируем по убыванию давности
        NTILE(5) OVER (ORDER BY recency_days DESC)                AS r_score,
        -- F: пороги вручную, см. блок A
        CASE WHEN frequency >= 6 THEN 5
             WHEN frequency  = 5 THEN 4
             WHEN frequency  = 4 THEN 4
             WHEN frequency  = 3 THEN 3
             WHEN frequency  = 2 THEN 2
             ELSE 1 END                                           AS f_score,
        NTILE(5) OVER (ORDER BY monetary)                         AS m_score,
        -- относительное положение клиента в базе по деньгам
        ROUND(PERCENT_RANK() OVER (ORDER BY monetary), 3)         AS monetary_pctile
    FROM base
),
segmented AS (
    SELECT
        scored.*,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 THEN '1. Чемпионы'
            WHEN r_score >= 3 AND f_score >= 3 THEN '2. Лояльные'
            WHEN r_score >= 4 AND f_score <= 2 THEN '3. Новые / перспективные'
            WHEN r_score  = 3 AND f_score <= 2 THEN '4. Требуют внимания'
            WHEN r_score <= 2 AND f_score >= 3 THEN '5. Под угрозой (были ценными)'
            WHEN r_score <= 2 AND f_score <= 2 THEN '6. Спящие'
            ELSE '7. Прочие'
        END AS segment
    FROM scored
)
SELECT
    segment,
    COUNT(*)                                                          AS customers,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                AS cust_share_pct,
    ROUND(AVG(recency_days))                                          AS avg_recency_days,
    ROUND(AVG(frequency), 2)                                          AS avg_frequency,
    ROUND(AVG(monetary))                                              AS avg_monetary,
    ROUND(SUM(monetary))                                              AS total_revenue,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1)      AS rev_share_pct,
    ROUND(SUM(contribution))                                          AS total_contribution,
    -- во сколько раз доля в деньгах отличается от доли в головах
    ROUND((SUM(monetary) / SUM(SUM(monetary)) OVER ())
        / (1.0 * COUNT(*) / SUM(COUNT(*))  OVER ()), 2)               AS value_concentration
FROM segmented
GROUP BY segment
ORDER BY segment;


.print ""
.print "=== C. Деньги под угрозой: кто уходит и сколько уносит ==="
.print ""

WITH ref AS (SELECT MAX(order_ts) AS as_of FROM v_orders_enriched),
base AS (
    SELECT c.customer_id,
           CAST(julianday((SELECT as_of FROM ref)) - julianday(MAX(o.order_ts)) AS INTEGER) AS recency_days,
           COUNT(DISTINCT o.order_id) AS frequency,
           SUM(o.order_revenue)       AS monetary
    FROM v_customer_cohort c
    JOIN v_orders_enriched o ON o.customer_id = c.customer_id
    GROUP BY c.customer_id
),
scored AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        CASE WHEN frequency >= 6 THEN 5 WHEN frequency >= 4 THEN 4
             WHEN frequency  = 3 THEN 3 WHEN frequency = 2 THEN 2 ELSE 1 END AS f_score,
        NTILE(5) OVER (ORDER BY monetary) AS m_score
    FROM base
)
SELECT
    CASE WHEN r_score <= 2 AND f_score >= 3 THEN 'Под угрозой (F>=3, давно не покупал)'
         WHEN r_score <= 2 AND m_score = 5  THEN 'Спящий, но был крупным (M=5)'
         ELSE 'Остальные' END                                    AS risk_group,
    COUNT(*)                                                     AS customers,
    ROUND(SUM(monetary))                                         AS revenue_at_risk,
    ROUND(100.0 * SUM(monetary) / SUM(SUM(monetary)) OVER (), 1) AS pct_of_total_revenue,
    ROUND(AVG(recency_days))                                     AS avg_days_since_last
FROM scored
GROUP BY risk_group
ORDER BY revenue_at_risk DESC;


.print ""
.print "=== D. Из каких каналов приходят чемпионы ==="
.print ""

WITH ref AS (SELECT MAX(order_ts) AS as_of FROM v_orders_enriched),
base AS (
    SELECT c.customer_id, c.acquisition_channel,
           CAST(julianday((SELECT as_of FROM ref)) - julianday(MAX(o.order_ts)) AS INTEGER) AS recency_days,
           COUNT(DISTINCT o.order_id) AS frequency,
           SUM(o.order_revenue)       AS monetary
    FROM v_customer_cohort c
    JOIN v_orders_enriched o ON o.customer_id = c.customer_id
    GROUP BY c.customer_id, c.acquisition_channel
),
scored AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,
        CASE WHEN frequency >= 6 THEN 5 WHEN frequency >= 4 THEN 4
             WHEN frequency  = 3 THEN 3 WHEN frequency = 2 THEN 2 ELSE 1 END AS f_score
    FROM base
)
SELECT
    acquisition_channel                                                       AS channel,
    COUNT(*)                                                                  AS customers,
    SUM(CASE WHEN r_score >= 4 AND f_score >= 4 THEN 1 ELSE 0 END)             AS champions,
    ROUND(100.0 * SUM(CASE WHEN r_score >= 4 AND f_score >= 4 THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                                      AS champion_rate_pct,
    ROUND(AVG(monetary))                                                      AS avg_ltv_revenue,
    RANK() OVER (ORDER BY 1.0 * SUM(CASE WHEN r_score >= 4 AND f_score >= 4
                                         THEN 1 ELSE 0 END) / COUNT(*) DESC)  AS rank_by_champion_rate
FROM scored
GROUP BY acquisition_channel
ORDER BY champion_rate_pct DESC;

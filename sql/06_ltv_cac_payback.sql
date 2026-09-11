-- =====================================================================
--  ВОПРОС 6. LTV, CAC и окупаемость каналов привлечения
--
--  Бизнес-вопрос: какие каналы приносят прибыль, а какие покупают
--  убыточных клиентов? Через сколько месяцев канал возвращает вложенное?
--
--  Зависимости: sql/00_setup_views.sql
--
--  ДВА РЕШЕНИЯ, БЕЗ КОТОРЫХ ЦИФРЫ БУДУТ ВРАТЬ:
--
--  1. ТОЛЬКО ЗРЕЛЫЕ КОГОРТЫ. LTV за 12 месяцев можно считать лишь по
--     клиентам, которые прожили эти 12 месяцев. Если взять всю базу и
--     поделить накопленную выручку на общее число клиентов, свежие
--     когорты (у которых ещё нет 12 месяцев истории) размоют знаменатель
--     и LTV окажется заниженным. Ниже берутся только когорты с полными
--     12 месяцами наблюдения.
--
--  2. LTV СЧИТАЕТСЯ В ПРИБЫЛИ, А НЕ В ВЫРУЧКЕ. Сравнивать выручку с
--     CAC бессмысленно: из выручки ещё нужно вычесть себестоимость,
--     возвраты и доставку. Здесь используется order_contribution —
--     вклад после всех трёх. Выручка показана рядом для сравнения.
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Накопленный LTV на клиента по месяцам жизни ==="
.print "    Только когорты с полными 12 месяцами наблюдения"
.print ""

WITH bounds AS (
    SELECT MAX(CAST(strftime('%Y', order_ts) AS INTEGER) * 12
             + CAST(strftime('%m', order_ts) AS INTEGER)) AS last_idx
    FROM v_orders_enriched
),
mature AS (
    SELECT cc.customer_id, cc.acquisition_channel, cc.cohort_month, cc.cohort_idx
    FROM v_customer_cohort cc
    CROSS JOIN bounds b
    WHERE cc.cohort_idx <= b.last_idx - 11        -- нужны месяцы жизни 0..11
),
cohort_base AS (
    SELECT acquisition_channel, COUNT(*) AS customers
    FROM mature GROUP BY acquisition_channel
),
orders_in_window AS (
    SELECT
        m.acquisition_channel,
        (CAST(strftime('%Y', o.order_ts) AS INTEGER) * 12
       + CAST(strftime('%m', o.order_ts) AS INTEGER)) - m.cohort_idx AS month_of_life,
        o.order_revenue,
        o.order_contribution
    FROM v_orders_enriched o
    JOIN mature m ON m.customer_id = o.customer_id
),
per_offset AS (
    SELECT acquisition_channel, month_of_life,
           SUM(order_revenue)      AS revenue,
           SUM(order_contribution) AS contribution
    FROM orders_in_window
    WHERE month_of_life BETWEEN 0 AND 11
    GROUP BY acquisition_channel, month_of_life
),
cumulative AS (
    SELECT
        p.acquisition_channel,
        p.month_of_life,
        -- накопление нарастающим итогом внутри канала, делённое на
        -- фиксированный размер когорты -> LTV на одного клиента
        SUM(p.revenue)      OVER (PARTITION BY p.acquisition_channel
                                  ORDER BY p.month_of_life) / cb.customers AS cum_rev_per_cust,
        SUM(p.contribution) OVER (PARTITION BY p.acquisition_channel
                                  ORDER BY p.month_of_life) / cb.customers AS cum_contrib_per_cust
    FROM per_offset p
    JOIN cohort_base cb ON cb.acquisition_channel = p.acquisition_channel
)
SELECT
    acquisition_channel AS channel,
    ROUND(MAX(CASE WHEN month_of_life = 0  THEN cum_contrib_per_cust END), 2) AS m0,
    ROUND(MAX(CASE WHEN month_of_life = 1  THEN cum_contrib_per_cust END), 2) AS m1,
    ROUND(MAX(CASE WHEN month_of_life = 3  THEN cum_contrib_per_cust END), 2) AS m3,
    ROUND(MAX(CASE WHEN month_of_life = 6  THEN cum_contrib_per_cust END), 2) AS m6,
    ROUND(MAX(CASE WHEN month_of_life = 11 THEN cum_contrib_per_cust END), 2) AS m12_profit,
    ROUND(MAX(CASE WHEN month_of_life = 11 THEN cum_rev_per_cust END), 2)     AS m12_revenue
FROM cumulative
GROUP BY acquisition_channel
ORDER BY m12_profit DESC;


.print ""
.print "=== B. LTV против CAC: окупается ли канал ==="
.print ""

WITH bounds AS (
    SELECT MAX(CAST(strftime('%Y', order_ts) AS INTEGER) * 12
             + CAST(strftime('%m', order_ts) AS INTEGER)) AS last_idx
    FROM v_orders_enriched
),
mature AS (
    SELECT cc.customer_id, cc.acquisition_channel, cc.cohort_month, cc.cohort_idx
    FROM v_customer_cohort cc CROSS JOIN bounds b
    WHERE cc.cohort_idx <= b.last_idx - 11
),
cohort_base AS (
    SELECT acquisition_channel, COUNT(*) AS customers FROM mature GROUP BY 1
),
-- CAC берём за ТЕ ЖЕ месяцы, в которые привлекались эти клиенты,
-- иначе сравнивали бы LTV одной когорты со стоимостью другой
acq_months AS (
    SELECT acquisition_channel AS channel, cohort_month, COUNT(*) AS acquired
    FROM mature GROUP BY 1, 2
),
cac AS (
    SELECT
        a.channel,
        SUM(ms.spend_amount)                    AS spend,
        SUM(a.acquired)                         AS acquired,
        SUM(ms.spend_amount) / SUM(a.acquired)  AS cac
    FROM acq_months a
    JOIN marketing_spend ms
      ON ms.channel = a.channel AND ms.spend_month = a.cohort_month
    GROUP BY a.channel
),
per_offset AS (
    SELECT m.acquisition_channel,
           (CAST(strftime('%Y', o.order_ts) AS INTEGER) * 12
          + CAST(strftime('%m', o.order_ts) AS INTEGER)) - m.cohort_idx AS mol,
           SUM(o.order_contribution) AS contribution
    FROM v_orders_enriched o
    JOIN mature m ON m.customer_id = o.customer_id
    GROUP BY 1, 2
    HAVING mol BETWEEN 0 AND 11
),
cumulative AS (
    SELECT p.acquisition_channel, p.mol,
           SUM(p.contribution) OVER (PARTITION BY p.acquisition_channel
                                     ORDER BY p.mol) / cb.customers AS cum_contrib
    FROM per_offset p
    JOIN cohort_base cb ON cb.acquisition_channel = p.acquisition_channel
)
SELECT
    c.acquisition_channel                                        AS channel,
    cb.customers,
    ROUND(cac.cac, 2)                                            AS cac,
    ROUND(MAX(CASE WHEN mol = 11 THEN cum_contrib END), 2)       AS ltv12_profit,
    -- отношение LTV к CAC; для органических каналов CAC = 0 -> NULL
    ROUND(MAX(CASE WHEN mol = 11 THEN cum_contrib END)
          / NULLIF(cac.cac, 0), 2)                               AS ltv_cac_ratio,
    -- первый месяц жизни, в котором накопленная прибыль перекрыла CAC
    MIN(CASE WHEN cum_contrib >= cac.cac THEN mol END)           AS payback_month,
    ROUND(MAX(CASE WHEN mol = 11 THEN cum_contrib END) * cb.customers
          - cac.cac * cb.customers)                              AS profit_12m_total
FROM cumulative c
JOIN cohort_base cb ON cb.acquisition_channel = c.acquisition_channel
JOIN cac            ON cac.channel            = c.acquisition_channel
GROUP BY c.acquisition_channel
ORDER BY ltv_cac_ratio DESC NULLS LAST;


.print ""
.print "=== C. CAC растёт: динамика стоимости привлечения по кварталам ==="
.print ""

WITH q AS (
    SELECT
        ms.channel,
        substr(ms.spend_month, 1, 4) || '-Q'
          || ((CAST(substr(ms.spend_month, 6, 2) AS INTEGER) + 2) / 3) AS quarter,
        SUM(ms.spend_amount) AS spend,
        SUM(COALESCE(a.acquired, 0)) AS acquired
    FROM marketing_spend ms
    LEFT JOIN (
        SELECT acquisition_channel AS channel, cohort_month, COUNT(*) AS acquired
        FROM v_customer_cohort GROUP BY 1, 2
    ) a ON a.channel = ms.channel AND a.cohort_month = ms.spend_month
    WHERE ms.spend_amount > 0
    GROUP BY ms.channel, quarter
),
cac_q AS (
    SELECT channel, quarter, spend, acquired,
           spend / NULLIF(acquired, 0) AS cac
    FROM q
),
windowed AS (
    -- Окна считаются по ПОЛНОМУ ряду кварталов: WHERE отрабатывает раньше
    -- оконных функций, поэтому прореживание вынесено во внешний запрос.
    -- Иначе «первый квартал» оказался бы первым из отобранных, а не первым
    -- в истории канала.
    SELECT
        channel, quarter, acquired, cac,
        FIRST_VALUE(cac) OVER (PARTITION BY channel ORDER BY quarter) AS first_cac,
        LAG(cac)         OVER (PARTITION BY channel ORDER BY quarter) AS prev_cac
    FROM cac_q
)
SELECT
    channel,
    quarter,
    acquired,
    ROUND(cac, 2)                                       AS cac,
    -- рост CAC относительно САМОГО ПЕРВОГО квартала канала
    ROUND(100.0 * (cac - first_cac) / first_cac, 1)     AS vs_first_pct,
    -- изменение к НЕПОСРЕДСТВЕННО предыдущему кварталу (он может быть
    -- не показан в выборке — это ожидаемо, ряд прорежен для читаемости)
    ROUND(cac - prev_cac, 2)                            AS vs_prev_quarter
FROM windowed
WHERE quarter IN ('2024-Q1', '2025-Q1', '2026-Q1', '2026-Q3')
ORDER BY channel, quarter;


.print ""
.print "=== D. Сводка: доля бюджета против доли прибыли ==="
.print ""

WITH spend_total AS (
    SELECT channel, SUM(spend_amount) AS spend FROM marketing_spend GROUP BY channel
),
profit_total AS (
    SELECT cc.acquisition_channel AS channel,
           COUNT(DISTINCT cc.customer_id) AS customers,
           SUM(o.order_contribution)      AS contribution
    FROM v_customer_cohort cc
    JOIN v_orders_enriched o ON o.customer_id = cc.customer_id
    GROUP BY cc.acquisition_channel
)
SELECT
    p.channel,
    p.customers,
    ROUND(s.spend)                                                  AS marketing_spend,
    ROUND(100.0 * s.spend / SUM(s.spend) OVER (), 1)                AS spend_share_pct,
    ROUND(p.contribution)                                           AS contribution,
    ROUND(100.0 * p.contribution / SUM(p.contribution) OVER (), 1)  AS profit_share_pct,
    ROUND(p.contribution - s.spend)                                 AS net_after_marketing,
    -- отрицательное = канал съедает больше, чем приносит
    ROUND(100.0 * p.contribution / SUM(p.contribution) OVER ()
        - 100.0 * s.spend / SUM(s.spend) OVER (), 1)                AS profit_minus_spend_pp
FROM profit_total p
JOIN spend_total  s ON s.channel = p.channel
ORDER BY net_after_marketing DESC;

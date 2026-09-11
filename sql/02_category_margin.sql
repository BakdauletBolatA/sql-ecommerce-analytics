-- =====================================================================
--  ВОПРОС 2. Топ-категорий по марже
--
--  Бизнес-вопрос: какие категории реально зарабатывают деньги? Выручка
--  и прибыль — не одно и то же, а между «валовой маржой» и «деньгами в
--  кармане» стоят скидки и возвраты.
--
--  Зависимости: sql/00_setup_views.sql
--
--  Три уровня маржи, которые здесь считаются:
--    1) Валовая (gross)       = net_revenue - cogs
--    2) После возвратов (contribution) = gross - refunds
--    3) Доставка учитывается на уровне заказа (v_orders_enriched) и в
--       разрез категорий НЕ размазывается — аллокация доставки по
--       позициям была бы выдумкой. Её влияние показано отдельно в блоке E.
--
--  Главная проверяемая гипотеза: рейтинг категорий по ВЫРУЧКЕ и по
--  ПРИБЫЛИ ПОСЛЕ ВОЗВРАТОВ — это два разных рейтинга.
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Корневые категории: от выручки к прибыли ==="
.print ""

WITH cat_totals AS (
    SELECT
        top_category,
        COUNT(DISTINCT order_id)   AS orders,
        SUM(net_revenue)           AS revenue,
        SUM(cogs)                  AS cogs,
        SUM(gross_profit)          AS gross_profit,
        SUM(refund_amount)         AS refunds,
        SUM(contribution)          AS contribution,
        SUM(gross_revenue - net_revenue) AS discount_given
    FROM v_order_lines
    GROUP BY top_category
)
SELECT
    top_category                                                      AS category,
    ROUND(revenue)                                                    AS revenue,
    -- SUM(...) OVER () даёт долю от общего итога без второго прохода по данным
    ROUND(100.0 * revenue / SUM(revenue) OVER (), 1)                  AS rev_share_pct,
    ROUND(100.0 * gross_profit / revenue, 1)                          AS gross_m_pct,
    ROUND(100.0 * refunds / revenue, 1)                               AS refund_pct,
    ROUND(100.0 * contribution / revenue, 1)                          AS contrib_m_pct,
    ROUND(contribution)                                               AS contribution,
    ROUND(100.0 * contribution / SUM(contribution) OVER (), 1)        AS profit_share_pct,
    RANK() OVER (ORDER BY revenue DESC)                               AS rank_by_rev,
    RANK() OVER (ORDER BY contribution DESC)                          AS rank_by_profit,
    -- положительная дельта = категория «недооценена» рейтингом по выручке
    RANK() OVER (ORDER BY revenue DESC)
  - RANK() OVER (ORDER BY contribution DESC)                          AS rank_shift
FROM cat_totals
ORDER BY contribution DESC;


.print ""
.print "=== B. Листовые категории внутри своей ветки ==="
.print "    RANK() OVER (PARTITION BY ...) — ранг считается ВНУТРИ каждой ветки"
.print ""

WITH leaf_totals AS (
    SELECT
        top_category,
        leaf_category,
        SUM(net_revenue)   AS revenue,
        SUM(gross_profit)  AS gross_profit,
        SUM(refund_amount) AS refunds,
        SUM(contribution)  AS contribution
    FROM v_order_lines
    GROUP BY top_category, leaf_category
)
SELECT
    top_category                                                            AS parent,
    leaf_category                                                           AS category,
    ROUND(revenue)                                                          AS revenue,
    ROUND(100.0 * contribution / revenue, 1)                                AS contrib_m_pct,
    ROUND(contribution)                                                     AS contribution,
    -- доля листа внутри своей ветки
    ROUND(100.0 * contribution
          / SUM(contribution) OVER (PARTITION BY top_category), 1)          AS share_in_parent_pct,
    RANK() OVER (PARTITION BY top_category ORDER BY contribution DESC)      AS rank_in_parent,
    DENSE_RANK() OVER (ORDER BY 1.0 * contribution / revenue DESC)          AS rank_by_margin_all
FROM leaf_totals
ORDER BY top_category, rank_in_parent;


.print ""
.print "=== C. Сжатие маржи во времени (закупка дорожает быстрее цены) ==="
.print ""

WITH quarterly AS (
    SELECT
        substr(order_month, 1, 4) || '-Q'
          || ((CAST(substr(order_month, 6, 2) AS INTEGER) + 2) / 3)  AS quarter,
        top_category,
        SUM(net_revenue)  AS revenue,
        SUM(gross_profit) AS gross_profit,
        SUM(contribution) AS contribution
    FROM v_order_lines
    GROUP BY quarter, top_category
),
with_lag AS (
    SELECT
        quarter,
        top_category,
        ROUND(100.0 * gross_profit / revenue, 1) AS gross_m_pct,
        -- LAG(...) в пределах категории: сравниваем квартал с предыдущим
        ROUND(100.0 * gross_profit / revenue
            - LAG(100.0 * gross_profit / revenue)
              OVER (PARTITION BY top_category ORDER BY quarter), 1)          AS vs_prev_q_pp,
        -- FIRST_VALUE: насколько маржа ушла от самого первого квартала
        ROUND(100.0 * gross_profit / revenue
            - FIRST_VALUE(100.0 * gross_profit / revenue)
              OVER (PARTITION BY top_category ORDER BY quarter), 1)          AS vs_first_pp
    FROM quarterly
)
SELECT * FROM with_lag
WHERE quarter IN ('2024-Q1', '2025-Q1', '2026-Q1', '2026-Q3')
ORDER BY top_category, quarter;


.print ""
.print "=== D. Что скидка делает с маржой и с возвратами ==="
.print ""

WITH bucketed AS (
    SELECT
        CASE
            WHEN discount_pct = 0                        THEN '0. без скидки'
            WHEN discount_pct <= 0.10                    THEN '1. до 10%'
            WHEN discount_pct <= 0.20                    THEN '2. 10-20%'
            WHEN discount_pct <= 0.30                    THEN '3. 20-30%'
            ELSE                                              '4. свыше 30%'
        END                    AS discount_bucket,
        net_revenue, gross_profit, refund_amount, contribution, quantity, returned_qty
    FROM v_order_lines
)
SELECT
    discount_bucket,
    COUNT(*)                                                        AS lines,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)              AS share_of_lines_pct,
    ROUND(SUM(net_revenue))                                         AS revenue,
    ROUND(100.0 * SUM(gross_profit) / SUM(net_revenue), 1)          AS gross_m_pct,
    ROUND(100.0 * SUM(returned_qty) / SUM(quantity), 1)             AS return_rate_pct,
    ROUND(100.0 * SUM(contribution) / SUM(net_revenue), 1)          AS contrib_m_pct
FROM bucketed
GROUP BY discount_bucket
ORDER BY discount_bucket;


.print ""
.print "=== E. Влияние доставки: маржа заказа до и после логистики ==="
.print ""

WITH order_level AS (
    SELECT
        CASE WHEN order_revenue > 75 THEN 'корзина > 75 (доставка бесплатна)'
             ELSE 'корзина <= 75 (доставка платная)' END AS basket_type,
        order_revenue,
        order_gross_profit,
        order_refunds,
        shipping_cost,
        order_contribution
    FROM v_orders_enriched
)
SELECT
    basket_type,
    COUNT(*)                                                              AS orders,
    ROUND(AVG(order_revenue), 2)                                          AS avg_order_value,
    ROUND(100.0 * SUM(order_gross_profit) / SUM(order_revenue), 1)        AS gross_m_pct,
    ROUND(100.0 * (SUM(order_gross_profit) - SUM(order_refunds))
                / SUM(order_revenue), 1)                                  AS after_returns_pct,
    ROUND(100.0 * SUM(order_contribution) / SUM(order_revenue), 1)        AS after_shipping_pct
FROM order_level
GROUP BY basket_type;

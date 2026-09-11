-- =====================================================================
--  ВОПРОС 7. ABC-анализ ассортимента (правило Парето)
--
--  Бизнес-вопрос: какая часть каталога реально кормит бизнес, что можно
--  вывести из ассортимента и какие товары продаются много, но невыгодно?
--
--  Зависимости: sql/00_setup_views.sql
--
--  Классификация ABC строится по НАКОПЛЕННОЙ доле, а не по порогу
--  выручки отдельного товара:
--      A — товары, набирающие первые 80% выручки
--      B — следующие 15% (до 95%)
--      C — оставшийся хвост
--  Накопление считается оконной функцией
--      SUM(...) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING),
--  то есть ровно тем инструментом, ради которого оконные функции и нужны:
--  без них пришлось бы делать самосоединение таблицы с самой собой.
--
--  Отдельно считается ABC по ПРИБЫЛИ. Совпадение двух классификаций не
--  гарантировано — товар может быть в группе A по обороту и в C по
--  вкладу; такие позиции и есть главная находка блока C.
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Проверка правила Парето: сколько товаров дают 80% выручки ==="
.print ""

WITH product_totals AS (
    SELECT
        product_id,
        SUM(net_revenue)  AS revenue,
        SUM(contribution) AS contribution,
        SUM(quantity)     AS units
    FROM v_order_lines
    GROUP BY product_id
),
ranked AS (
    SELECT
        product_id, revenue, contribution, units,
        ROW_NUMBER() OVER (ORDER BY revenue DESC)                       AS rev_rank,
        -- накопленная доля выручки: ядро ABC-анализа
        SUM(revenue) OVER (ORDER BY revenue DESC, product_id
                           ROWS UNBOUNDED PRECEDING)
            / SUM(revenue) OVER ()                                      AS cum_rev_share,
        COUNT(*) OVER ()                                                AS total_products
    FROM product_totals
),
classified AS (
    SELECT *,
        CASE WHEN cum_rev_share <= 0.80 THEN 'A'
             WHEN cum_rev_share <= 0.95 THEN 'B'
             ELSE 'C' END AS abc_class
    FROM ranked
)
SELECT
    abc_class                                                     AS class,
    COUNT(*)                                                      AS products,
    ROUND(100.0 * COUNT(*) / MAX(total_products), 1)              AS pct_of_catalog,
    ROUND(SUM(revenue))                                           AS revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)    AS pct_of_revenue,
    ROUND(SUM(contribution))                                      AS contribution,
    ROUND(100.0 * SUM(contribution)
          / SUM(SUM(contribution)) OVER (), 1)                    AS pct_of_profit,
    ROUND(100.0 * SUM(contribution) / SUM(revenue), 1)            AS margin_pct
FROM classified
GROUP BY abc_class
ORDER BY abc_class;


.print ""
.print "=== B. Форма кривой концентрации по децилям каталога ==="
.print ""

WITH product_totals AS (
    SELECT product_id, SUM(net_revenue) AS revenue, SUM(contribution) AS contribution
    FROM v_order_lines GROUP BY product_id
),
deciled AS (
    SELECT product_id, revenue, contribution,
           NTILE(10) OVER (ORDER BY revenue DESC) AS decile
    FROM product_totals
)
SELECT
    decile,
    COUNT(*)                                                       AS products,
    ROUND(SUM(revenue))                                            AS revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 1)     AS pct_of_revenue,
    -- накопленная доля по децилям: та самая «кривая Парето» в цифрах
    ROUND(100.0 * SUM(SUM(revenue)) OVER (ORDER BY decile)
          / SUM(SUM(revenue)) OVER (), 1)                          AS cum_pct_revenue,
    ROUND(100.0 * SUM(contribution) / SUM(revenue), 1)             AS margin_pct
FROM deciled
GROUP BY decile
ORDER BY decile;


.print ""
.print "=== C. Ловушки ассортимента: много оборота, мало прибыли ==="
.print "    Класс A по выручке, но класс B/C по вкладу"
.print ""

WITH product_totals AS (
    SELECT
        l.product_id,
        MAX(l.product_name)  AS product_name,
        MAX(l.top_category)  AS top_category,
        SUM(l.net_revenue)   AS revenue,
        SUM(l.contribution)  AS contribution,
        SUM(l.refund_amount) AS refunds,
        SUM(l.quantity)      AS units
    FROM v_order_lines l
    GROUP BY l.product_id
),
dual_abc AS (
    SELECT *,
        CASE WHEN SUM(revenue) OVER (ORDER BY revenue DESC, product_id ROWS UNBOUNDED PRECEDING)
                  / SUM(revenue) OVER () <= 0.80 THEN 'A'
             WHEN SUM(revenue) OVER (ORDER BY revenue DESC, product_id ROWS UNBOUNDED PRECEDING)
                  / SUM(revenue) OVER () <= 0.95 THEN 'B'
             ELSE 'C' END AS abc_revenue,
        CASE WHEN SUM(contribution) OVER (ORDER BY contribution DESC, product_id ROWS UNBOUNDED PRECEDING)
                  / SUM(contribution) OVER () <= 0.80 THEN 'A'
             WHEN SUM(contribution) OVER (ORDER BY contribution DESC, product_id ROWS UNBOUNDED PRECEDING)
                  / SUM(contribution) OVER () <= 0.95 THEN 'B'
             ELSE 'C' END AS abc_profit,
        ROUND(100.0 * contribution / revenue, 1) AS margin_pct,
        RANK() OVER (ORDER BY revenue DESC)      AS rev_rank
    FROM product_totals
)
SELECT
    rev_rank, product_name, top_category AS category,
    ROUND(revenue)     AS revenue,
    ROUND(contribution) AS contribution,
    margin_pct,
    ROUND(refunds)     AS refunds,
    abc_revenue, abc_profit
FROM dual_abc
WHERE abc_revenue = 'A' AND abc_profit <> 'A'
ORDER BY revenue DESC
LIMIT 12;


.print ""
.print "=== D. Хвост каталога: что можно выводить из ассортимента ==="
.print ""

WITH product_totals AS (
    SELECT p.product_id, p.product_name, p.is_active,
           COALESCE(SUM(l.net_revenue), 0)  AS revenue,
           COALESCE(SUM(l.contribution), 0) AS contribution,
           COALESCE(SUM(l.quantity), 0)     AS units,
           COUNT(DISTINCT l.order_id)       AS orders,
           MAX(l.order_ts)                  AS last_sold_ts
    FROM products p
    LEFT JOIN v_order_lines l ON l.product_id = p.product_id
    GROUP BY p.product_id
),
flagged AS (
    SELECT *,
        NTILE(10) OVER (ORDER BY revenue DESC) AS decile,
        CASE
            WHEN orders = 0                                   THEN '4. ни одной продажи'
            WHEN contribution < 0                             THEN '3. убыточный'
            WHEN last_sold_ts < (SELECT MAX(order_ts) FROM v_order_lines)
                 AND julianday((SELECT MAX(order_ts) FROM v_order_lines))
                   - julianday(last_sold_ts) > 180            THEN '2. не продавался 180+ дней'
            ELSE '1. активный'
        END AS status
    FROM product_totals
)
SELECT
    status,
    COUNT(*)                                                    AS products,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)          AS pct_of_catalog,
    ROUND(SUM(revenue))                                         AS revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2)  AS pct_of_revenue,
    ROUND(SUM(contribution))                                    AS contribution
FROM flagged
GROUP BY status
ORDER BY status;

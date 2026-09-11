-- =====================================================================
--  ВОПРОС 4. Сезонность и тренд
--
--  Бизнес-вопрос: бизнес реально растёт — или это просто ноябрь? Какая
--  часть роста сезонная, а какая настоящая? Когда нужно закупать товар?
--
--  Зависимости: sql/00_setup_views.sql
--
--  Метод: классическая декомпозиция «отношение к скользящей средней»
--  (ratio-to-moving-average):
--    1) Считаем ЦЕНТРИРОВАННОЕ скользящее среднее за 12 месяцев (CMA-12).
--       Окно в 12 месяцев по построению «съедает» сезонность.
--    2) ratio = факт / CMA-12  — это сезонная компонента месяца.
--    3) Сезонный индекс календарного месяца = среднее его ratio по годам.
--    4) Очищенный ряд = факт / индекс -> виден настоящий тренд.
--
--  Тонкость, из-за которой обычно ошибаются: на краях ряда (первые 6 и
--  последние 5 месяцев) полного окна нет. SQLite молча посчитает среднее
--  по неполному окну, и края будут врать. Ниже эти месяцы явно
--  превращаются в NULL через COUNT(*) OVER w = 12.
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Помесячная динамика: MoM, YoY и скользящее среднее ==="
.print ""

WITH monthly AS (
    SELECT
        order_month,
        COUNT(DISTINCT order_id) AS orders,
        SUM(net_revenue)         AS revenue
    FROM v_order_lines
    GROUP BY order_month
)
SELECT
    order_month                                                            AS month,
    orders,
    ROUND(revenue)                                                         AS revenue,
    ROUND(revenue / orders, 2)                                             AS aov,
    -- месяц к месяцу
    ROUND(100.0 * (revenue - LAG(revenue) OVER w) / LAG(revenue) OVER w, 1) AS mom_pct,
    -- год к году: LAG на 12 позиций. Ряд непрерывный, поэтому смещение
    -- на 12 строк == смещение на 12 календарных месяцев
    ROUND(100.0 * (revenue - LAG(revenue, 12) OVER w)
          / LAG(revenue, 12) OVER w, 1)                                    AS yoy_pct,
    -- сглаживание 3 месяца: убирает всплески, оставляет направление
    ROUND(AVG(revenue) OVER (ORDER BY order_month
                             ROWS BETWEEN 2 PRECEDING AND CURRENT ROW))    AS ma3,
    -- накопительная выручка с начала наблюдений
    ROUND(SUM(revenue) OVER (ORDER BY order_month))                        AS cumulative_revenue
FROM monthly
WINDOW w AS (ORDER BY order_month)
ORDER BY order_month;


.print ""
.print "=== B. Сезонные индексы календарных месяцев ==="
.print "    индекс 1.00 = средний месяц; 1.70 = месяц в 1.7 раза выше нормы"
.print ""

WITH monthly AS (
    SELECT order_month, SUM(net_revenue) AS revenue
    FROM v_order_lines GROUP BY order_month
),
with_cma AS (
    SELECT
        order_month,
        revenue,
        -- CMA-12 только там, где окно ПОЛНОЕ; иначе NULL (см. шапку файла)
        CASE WHEN COUNT(*) OVER w = 12 THEN AVG(revenue) OVER w END AS cma12
    FROM monthly
    WINDOW w AS (ORDER BY order_month ROWS BETWEEN 6 PRECEDING AND 5 FOLLOWING)
),
ratios AS (
    SELECT
        CAST(substr(order_month, 6, 2) AS INTEGER) AS cal_month,
        revenue / cma12                            AS seasonal_ratio
    FROM with_cma
    WHERE cma12 IS NOT NULL
)
SELECT
    cal_month                                              AS month_no,
    COUNT(*)                                               AS observations,
    ROUND(AVG(seasonal_ratio), 3)                          AS seasonal_index,
    -- ранг месяца по «горячести»
    RANK() OVER (ORDER BY AVG(seasonal_ratio) DESC)        AS rank_hot,
    CASE WHEN AVG(seasonal_ratio) >= 1.15 THEN 'пик'
         WHEN AVG(seasonal_ratio) <= 0.85 THEN 'провал'
         ELSE 'норма' END                                  AS regime
FROM ratios
GROUP BY cal_month
ORDER BY cal_month;


.print ""
.print "=== C. Очищенный от сезонности тренд ==="
.print "    Если очищенный ряд растёт — растёт сам бизнес, а не календарь"
.print ""

WITH monthly AS (
    SELECT order_month, SUM(net_revenue) AS revenue
    FROM v_order_lines GROUP BY order_month
),
with_cma AS (
    SELECT order_month, revenue,
           CASE WHEN COUNT(*) OVER w = 12 THEN AVG(revenue) OVER w END AS cma12
    FROM monthly
    WINDOW w AS (ORDER BY order_month ROWS BETWEEN 6 PRECEDING AND 5 FOLLOWING)
),
seasonal_index AS (
    SELECT CAST(substr(order_month, 6, 2) AS INTEGER) AS cal_month,
           AVG(revenue / cma12)                       AS idx
    FROM with_cma WHERE cma12 IS NOT NULL
    GROUP BY cal_month
),
adjusted AS (
    SELECT
        m.order_month,
        m.revenue,
        si.idx,
        m.revenue / si.idx AS revenue_sa          -- seasonally adjusted
    FROM monthly m
    JOIN seasonal_index si
      ON si.cal_month = CAST(substr(m.order_month, 6, 2) AS INTEGER)
)
SELECT
    order_month                                                        AS month,
    ROUND(revenue)                                                     AS revenue_raw,
    ROUND(idx, 3)                                                      AS seasonal_idx,
    ROUND(revenue_sa)                                                  AS revenue_adjusted,
    -- прирост очищенного ряда: это и есть «настоящий» рост
    ROUND(100.0 * (revenue_sa - LAG(revenue_sa) OVER (ORDER BY order_month))
          / LAG(revenue_sa) OVER (ORDER BY order_month), 1)            AS sa_mom_pct,
    ROUND(AVG(revenue_sa) OVER (ORDER BY order_month
                                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)) AS sa_ma3
FROM adjusted
ORDER BY order_month;


.print ""
.print "=== D. Внутринедельный и внутрисуточный профиль ==="
.print ""

WITH by_dow AS (
    SELECT
        CAST(strftime('%w', order_ts) AS INTEGER)  AS dow_no,
        CASE strftime('%w', order_ts)
            WHEN '0' THEN 'вс' WHEN '1' THEN 'пн' WHEN '2' THEN 'вт'
            WHEN '3' THEN 'ср' WHEN '4' THEN 'чт' WHEN '5' THEN 'пт'
            ELSE 'сб' END                          AS dow,
        COUNT(DISTINCT order_id)                   AS orders,
        SUM(net_revenue)                           AS revenue
    FROM v_order_lines
    GROUP BY dow_no, dow
)
SELECT
    dow,
    orders,
    ROUND(revenue)                                          AS revenue,
    -- индекс дня недели относительно среднего дня
    ROUND(1.0 * orders / AVG(orders) OVER (), 3)            AS dow_index,
    ROUND(100.0 * orders / SUM(orders) OVER (), 1)          AS share_pct
FROM by_dow
ORDER BY dow_no;

.print ""

WITH by_hour AS (
    SELECT CAST(strftime('%H', order_ts) AS INTEGER) AS hour,
           COUNT(DISTINCT order_id)                  AS orders
    FROM v_order_lines GROUP BY hour
),
indexed AS (
    -- ЛОВУШКА ПОРЯДКА ВЫПОЛНЕНИЯ: WHERE отрабатывает РАНЬШЕ оконных функций.
    -- Если поставить фильтр «каждый третий час» прямо здесь, то AVG() OVER ()
    -- и SUM() OVER () посчитаются по восьми строкам вместо суток, и индекс
    -- с накопленной долей будут неверными. Поэтому окна считаются по всем
    -- 24 часам здесь, а прореживание вынесено во ВНЕШНИЙ запрос.
    SELECT
        hour,
        orders,
        ROUND(1.0 * orders / AVG(orders) OVER (), 2)                   AS hour_index,
        ROUND(100.0 * SUM(orders) OVER (ORDER BY hour)
              / SUM(orders) OVER (), 1)                                AS cum_share_pct
    FROM by_hour
)
SELECT hour, orders, hour_index, cum_share_pct
FROM indexed
WHERE hour % 3 = 0                                                 -- каждый третий час
ORDER BY hour;


.print ""
.print "=== E. У разных категорий пик приходится на разные месяцы ==="
.print "    Считаем по ПОЛНЫМ годам: 2026 обрывается на августе"
.print ""

WITH cat_month_year AS (
    SELECT
        top_category,
        substr(order_month, 1, 4)                  AS yr,
        CAST(substr(order_month, 6, 2) AS INTEGER) AS cal_month,
        SUM(net_revenue)                           AS revenue
    FROM v_order_lines
    -- ЛОВУШКА: если просто сгруппировать по номеру месяца по всем данным,
    -- у месяцев 01-08 окажется три наблюдения, а у 09-12 — два, и первая
    -- половина года механически «выиграет». Плюс 2026 год крупнее по
    -- обороту, что добавит перекос. Поэтому берём только полные годы.
    WHERE substr(order_month, 1, 4) IN ('2024', '2025')
    GROUP BY top_category, yr, cal_month
),
indexed_year AS (
    -- нормируем месяц на средний месяц СВОЕГО года и СВОЕЙ категории:
    -- так из индекса уходит и рост бизнеса, и разный масштаб категорий
    SELECT
        top_category, yr, cal_month, revenue,
        revenue / AVG(revenue) OVER (PARTITION BY top_category, yr) AS month_index
    FROM cat_month_year
),
avg_index AS (
    SELECT top_category, cal_month,
           AVG(month_index) AS cat_index,
           COUNT(*)         AS years_observed
    FROM indexed_year
    GROUP BY top_category, cal_month
),
ranked AS (
    -- ранг считается по ВСЕМ 12 месяцам категории; фильтр «только пики и
    -- провалы» применяется после, иначе ранг был бы внутри выборки
    SELECT *,
           RANK() OVER (PARTITION BY top_category ORDER BY cat_index DESC) AS peak_rank
    FROM avg_index
)
SELECT
    top_category        AS category,
    cal_month           AS month_no,
    ROUND(cat_index, 2) AS cat_index,
    years_observed      AS years,
    peak_rank
FROM ranked
WHERE cat_index >= 1.15 OR cat_index <= 0.80      -- только выраженные пики и провалы
ORDER BY top_category, cat_index DESC;

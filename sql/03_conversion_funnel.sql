-- =====================================================================
--  ВОПРОС 3. Воронка конверсии
--
--  Бизнес-вопрос: на каком шаге мы теряем больше всего денег и у каких
--  сегментов трафика воронка «дырявая»?
--
--  Зависимости: только базовые таблицы (sessions, events, orders)
--
--  Модель воронки — 5 шагов, строго вложенных:
--      сессия -> просмотр товара -> корзина -> оформление -> покупка
--
--  Два методических момента:
--   1. Шаг «сессия» берётся из таблицы sessions, а не из событий:
--      старт сессии — это сама строка сессии, дублировать его событием
--      значило бы хранить одно и то же дважды.
--   2. Считаем СЕССИИ, дошедшие до шага, а не количество событий.
--      Пользователь, посмотревший 4 товара, — это одна сессия на шаге
--      «просмотр», иначе конверсия шага может превысить 100%.
--
--  ВАЖНО ПРО ДАННЫЕ: в лог попадают только вовлечённые сессии (отказы и
--  боты отфильтрованы на стороне трекера), поэтому конверсия «сессия ->
--  покупка» здесь выше типичных для рынка 2-3%. Сравнивать имеет смысл
--  СЕГМЕНТЫ МЕЖДУ СОБОЙ, а не абсолютный уровень с бенчмарками.
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Общая воронка: конверсия шага и абсолютные потери ==="
.print ""

WITH session_steps AS (
    -- Схлопываем лог событий до одной строки на сессию: дошёл/не дошёл.
    -- MAX(CASE ...) — классический приём разворота событий в флаги.
    SELECT
        s.session_id,
        s.device,
        s.traffic_source,
        MAX(CASE WHEN e.event_type = 'product_view'   THEN 1 ELSE 0 END) AS did_view,
        MAX(CASE WHEN e.event_type = 'add_to_cart'    THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN e.event_type = 'checkout_start' THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN e.event_type = 'purchase'       THEN 1 ELSE 0 END) AS did_purchase
    FROM sessions s
    LEFT JOIN events e ON e.session_id = s.session_id
    GROUP BY s.session_id
),
funnel AS (
    SELECT 1 AS step_no, '1. сессия'          AS step_name, COUNT(*)          AS cnt FROM session_steps
    UNION ALL SELECT 2, '2. просмотр товара', SUM(did_view)                          FROM session_steps
    UNION ALL SELECT 3, '3. корзина',         SUM(did_cart)                          FROM session_steps
    UNION ALL SELECT 4, '4. оформление',      SUM(did_checkout)                      FROM session_steps
    UNION ALL SELECT 5, '5. покупка',         SUM(did_purchase)                      FROM session_steps
)
SELECT
    step_name,
    cnt                                                                   AS sessions,
    -- конверсия ЭТОГО шага из предыдущего
    ROUND(100.0 * cnt / LAG(cnt) OVER (ORDER BY step_no), 1)              AS step_cvr_pct,
    -- сквозная конверсия от вершины воронки
    ROUND(100.0 * cnt / FIRST_VALUE(cnt) OVER (ORDER BY step_no), 2)      AS from_top_pct,
    -- абсолютная потеря на шаге: где чинить в первую очередь
    LAG(cnt) OVER (ORDER BY step_no) - cnt                                AS lost_here,
    ROUND(100.0 * (LAG(cnt) OVER (ORDER BY step_no) - cnt)
          / FIRST_VALUE(cnt) OVER (ORDER BY step_no), 1)                  AS lost_pct_of_top
FROM funnel
ORDER BY step_no;


.print ""
.print "=== B. Воронка в разрезе устройств ==="
.print "    PARTITION BY device — LAG не «перетекает» между устройствами"
.print ""

WITH session_steps AS (
    SELECT s.session_id, s.device, s.traffic_source,
        MAX(CASE WHEN e.event_type = 'product_view'   THEN 1 ELSE 0 END) AS did_view,
        MAX(CASE WHEN e.event_type = 'add_to_cart'    THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN e.event_type = 'checkout_start' THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN e.event_type = 'purchase'       THEN 1 ELSE 0 END) AS did_purchase
    FROM sessions s
    LEFT JOIN events e ON e.session_id = s.session_id
    GROUP BY s.session_id
),
agg AS (
    SELECT device,
           COUNT(*)          AS s1, SUM(did_view)     AS s2, SUM(did_cart) AS s3,
           SUM(did_checkout) AS s4, SUM(did_purchase) AS s5
    FROM session_steps GROUP BY device
),
unpivoted AS (
    SELECT device, 1 AS step_no, '1. сессия'          AS step_name, s1 AS cnt FROM agg
    UNION ALL SELECT device, 2, '2. просмотр товара', s2 FROM agg
    UNION ALL SELECT device, 3, '3. корзина',         s3 FROM agg
    UNION ALL SELECT device, 4, '4. оформление',      s4 FROM agg
    UNION ALL SELECT device, 5, '5. покупка',         s5 FROM agg
)
SELECT
    device,
    step_name,
    cnt                                                                        AS sessions,
    ROUND(100.0 * cnt / LAG(cnt) OVER (PARTITION BY device ORDER BY step_no), 1)   AS step_cvr_pct,
    ROUND(100.0 * cnt / FIRST_VALUE(cnt) OVER (PARTITION BY device ORDER BY step_no), 2) AS from_top_pct
FROM unpivoted
ORDER BY device, step_no;


.print ""
.print "=== C. Качество трафика по источникам ==="
.print "    Объём и качество — разные вещи; сортируем по сквозной конверсии"
.print ""

WITH session_steps AS (
    SELECT s.session_id, s.traffic_source,
        MAX(CASE WHEN e.event_type = 'product_view'   THEN 1 ELSE 0 END) AS did_view,
        MAX(CASE WHEN e.event_type = 'add_to_cart'    THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN e.event_type = 'checkout_start' THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN e.event_type = 'purchase'       THEN 1 ELSE 0 END) AS did_purchase
    FROM sessions s
    LEFT JOIN events e ON e.session_id = s.session_id
    GROUP BY s.session_id
),
by_source AS (
    SELECT traffic_source,
           COUNT(*) AS sessions, SUM(did_view) AS views, SUM(did_cart) AS carts,
           SUM(did_checkout) AS checkouts, SUM(did_purchase) AS purchases
    FROM session_steps GROUP BY traffic_source
)
SELECT
    traffic_source                                                   AS source,
    sessions,
    ROUND(100.0 * sessions / SUM(sessions) OVER (), 1)               AS traffic_share_pct,
    ROUND(100.0 * carts / views, 1)                                  AS view_to_cart_pct,
    ROUND(100.0 * purchases / checkouts, 1)                          AS checkout_to_buy_pct,
    ROUND(100.0 * purchases / sessions, 2)                           AS overall_cvr_pct,
    ROUND(100.0 * purchases / SUM(purchases) OVER (), 1)             AS order_share_pct,
    RANK() OVER (ORDER BY 1.0 * purchases / sessions DESC)           AS rank_by_cvr,
    RANK() OVER (ORDER BY sessions DESC)                             AS rank_by_volume
FROM by_source
ORDER BY overall_cvr_pct DESC;


.print ""
.print "=== D. Пересечение устройство x источник: где именно течёт ==="
.print "    Только сегменты от 5000 сессий, чтобы не ловить шум"
.print ""

WITH session_steps AS (
    SELECT s.session_id, s.device, s.traffic_source,
        MAX(CASE WHEN e.event_type = 'checkout_start' THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN e.event_type = 'purchase'       THEN 1 ELSE 0 END) AS did_purchase
    FROM sessions s
    LEFT JOIN events e ON e.session_id = s.session_id
    GROUP BY s.session_id
),
seg AS (
    SELECT device, traffic_source,
           COUNT(*) AS sessions, SUM(did_checkout) AS checkouts, SUM(did_purchase) AS purchases
    FROM session_steps
    GROUP BY device, traffic_source
    HAVING COUNT(*) >= 5000
)
SELECT
    device, traffic_source AS source, sessions,
    ROUND(100.0 * purchases / checkouts, 1)                              AS checkout_to_buy_pct,
    ROUND(100.0 * purchases / sessions, 2)                               AS overall_cvr_pct,
    -- отклонение сегмента от среднего по его устройству
    ROUND(100.0 * purchases / sessions
        - AVG(100.0 * purchases / sessions) OVER (PARTITION BY device), 2) AS vs_device_avg_pp
FROM seg
ORDER BY overall_cvr_pct DESC;

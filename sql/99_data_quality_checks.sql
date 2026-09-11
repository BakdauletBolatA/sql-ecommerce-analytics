-- =====================================================================
--  99. ПРОВЕРКИ КАЧЕСТВА ДАННЫХ
--
--  Запускается перед любым доверием к цифрам. Каждая проверка построена
--  так, чтобы ИСПРАВНОЕ состояние давало 0 или 'OK': отчёт можно читать
--  по столбцу verdict, не вчитываясь в запросы.
--
--  Зависимости: sql/00_setup_views.sql
-- =====================================================================

.headers on
.mode column

.print ""
.print "=== A. Ссылочная целостность (везде должно быть 0) ==="
.print ""

WITH checks AS (
    SELECT 'order_items -> orders'   AS check_name,
           COUNT(*) AS orphans
    FROM order_items oi LEFT JOIN orders o USING (order_id) WHERE o.order_id IS NULL
    UNION ALL
    SELECT 'order_items -> products',
           COUNT(*) FROM order_items oi
    LEFT JOIN products p USING (product_id) WHERE p.product_id IS NULL
    UNION ALL
    SELECT 'orders -> customers',
           COUNT(*) FROM orders o
    LEFT JOIN customers c USING (customer_id) WHERE c.customer_id IS NULL
    UNION ALL
    SELECT 'payments -> orders',
           COUNT(*) FROM payments p
    LEFT JOIN orders o USING (order_id) WHERE o.order_id IS NULL
    UNION ALL
    SELECT 'order_returns -> order_items',
           COUNT(*) FROM order_returns r
    LEFT JOIN order_items oi USING (order_item_id) WHERE oi.order_item_id IS NULL
    UNION ALL
    SELECT 'events -> sessions',
           COUNT(*) FROM events e
    LEFT JOIN sessions s USING (session_id) WHERE s.session_id IS NULL
    UNION ALL
    SELECT 'products -> categories',
           COUNT(*) FROM products p
    LEFT JOIN categories c USING (category_id) WHERE c.category_id IS NULL
)
SELECT check_name, orphans,
       CASE WHEN orphans = 0 THEN 'OK' ELSE 'ОШИБКА' END AS verdict
FROM checks;


.print ""
.print "=== B. Логика значений ==="
.print ""

WITH checks AS (
    SELECT 'позиции с неположительным количеством' AS check_name,
           COUNT(*) AS bad FROM order_items WHERE quantity <= 0
    UNION ALL
    SELECT 'позиции с неположительной ценой',
           COUNT(*) FROM order_items WHERE unit_price <= 0
    UNION ALL
    SELECT 'скидка вне диапазона 0..1',
           COUNT(*) FROM order_items WHERE discount_pct < 0 OR discount_pct >= 1
    UNION ALL
    SELECT 'вернули больше, чем купили',
           COUNT(*) FROM (
               SELECT oi.order_item_id
               FROM order_items oi
               JOIN (SELECT order_item_id, SUM(quantity_returned) q
                     FROM order_returns GROUP BY 1) r USING (order_item_id)
               WHERE r.q > oi.quantity)
    UNION ALL
    SELECT 'возврат раньше заказа',
           COUNT(*) FROM order_returns r
           JOIN order_items oi USING (order_item_id)
           JOIN orders o USING (order_id)
           WHERE r.return_ts < o.order_ts
    UNION ALL
    SELECT 'доставка раньше заказа',
           COUNT(*) FROM orders WHERE delivered_ts IS NOT NULL AND delivered_ts < order_ts
    UNION ALL
    SELECT 'заказы без единой позиции',
           COUNT(*) FROM orders o
           LEFT JOIN order_items oi USING (order_id)
           WHERE oi.order_item_id IS NULL
    UNION ALL
    SELECT 'возвраты по отменённым заказам',
           COUNT(*) FROM order_returns r
           JOIN order_items oi USING (order_item_id)
           JOIN orders o USING (order_id)
           WHERE o.status = 'cancelled'
)
SELECT check_name, bad,
       CASE WHEN bad = 0 THEN 'OK' ELSE 'ОШИБКА' END AS verdict
FROM checks;


.print ""
.print "=== C. Сходимость событий и заказов ==="
.print "    Каждому событию purchase должен соответствовать ровно один заказ"
.print ""

WITH e AS (SELECT COUNT(*) AS purchase_events,
                  COUNT(DISTINCT order_id) AS distinct_orders_in_events
           FROM events WHERE event_type = 'purchase'),
o AS (SELECT COUNT(*) AS live_orders FROM orders WHERE status <> 'cancelled')
SELECT
    e.purchase_events,
    e.distinct_orders_in_events,
    o.live_orders,
    CASE WHEN e.purchase_events = o.live_orders
          AND e.distinct_orders_in_events = o.live_orders
         THEN 'OK' ELSE 'РАСХОЖДЕНИЕ' END AS verdict
FROM e CROSS JOIN o;


.print ""
.print "=== D. Сходимость денег: платежи против позиций заказа ==="
.print "    payments.amount должен равняться выручке заказа + доставка"
.print ""

WITH per_order AS (
    SELECT
        o.order_id,
        ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct)) + o.shipping_cost, 2) AS computed,
        ROUND(MAX(p.amount), 2) AS paid
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    JOIN payments   p  ON p.order_id  = o.order_id
    WHERE o.status <> 'cancelled'
    GROUP BY o.order_id, o.shipping_cost
)
SELECT
    COUNT(*)                                                     AS orders_checked,
    SUM(CASE WHEN ABS(computed - paid) > 0.02 THEN 1 ELSE 0 END) AS mismatches,
    ROUND(MAX(ABS(computed - paid)), 4)                          AS max_abs_diff,
    CASE WHEN SUM(CASE WHEN ABS(computed - paid) > 0.02 THEN 1 ELSE 0 END) = 0
         THEN 'OK' ELSE 'РАСХОЖДЕНИЕ' END                        AS verdict
FROM per_order;


.print ""
.print "=== E. Покрытие периода: нет ли дыр в помесячном ряду ==="
.print ""

WITH months AS (
    SELECT DISTINCT order_month FROM v_order_lines
),
seq AS (
    SELECT order_month,
           ROW_NUMBER() OVER (ORDER BY order_month) AS rn,
           CAST(substr(order_month,1,4) AS INTEGER) * 12
         + CAST(substr(order_month,6,2) AS INTEGER) AS idx
    FROM months
)
SELECT
    MIN(order_month)                    AS first_month,
    MAX(order_month)                    AS last_month,
    COUNT(*)                            AS months_present,
    MAX(idx) - MIN(idx) + 1             AS months_expected,
    CASE WHEN COUNT(*) = MAX(idx) - MIN(idx) + 1
         THEN 'OK' ELSE 'ЕСТЬ ПРОПУСКИ' END AS verdict
FROM seq;

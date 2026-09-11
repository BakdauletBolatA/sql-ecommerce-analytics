-- =====================================================================
--  00. БАЗОВЫЙ СЛОЙ ПРЕДСТАВЛЕНИЙ
--
--  Запускается ОДИН РАЗ перед остальными файлами:
--      sqlite3 data/ecommerce.db < sql/00_setup_views.sql
--
--  Зачем: определения «что такое выручка», «что такое маржа» и «что
--  такое когорта» должны существовать в одном месте. Если размазать их
--  по восьми файлам, рано или поздно два отчёта разойдутся в цифрах —
--  классическая болезнь аналитических репозиториев.
--
--  Вся аналитическая логика (CTE + оконные функции) остаётся в файлах
--  01-08; здесь только join'ы и денежные определения.
-- =====================================================================

DROP VIEW IF EXISTS v_order_lines;
DROP VIEW IF EXISTS v_orders_enriched;
DROP VIEW IF EXISTS v_customer_cohort;
DROP VIEW IF EXISTS v_category_tree;

-- ---------------------------------------------------------------------
-- v_category_tree — разворачивает иерархию категорий рекурсивным CTE.
--
-- Сейчас дерево двухуровневое и хватило бы self-join. Рекурсия выбрана
-- намеренно: при добавлении третьего уровня (Electronics > Audio >
-- Headphones) запрос НЕ придётся переписывать — он поднимется до корня
-- на любой глубине. Self-join пришлось бы дописывать каждый раз.
-- ---------------------------------------------------------------------
CREATE VIEW v_category_tree AS
WITH RECURSIVE up(category_id, ancestor_id, ancestor_name,
                  ancestor_level, depth) AS (
    -- якорь: каждая категория сама себе предок на глубине 0
    SELECT category_id, category_id, category_name, category_level, 0
    FROM categories

    UNION ALL

    -- шаг: поднимаемся к родителю, пока он есть
    SELECT u.category_id, c.category_id, c.category_name, c.category_level, u.depth + 1
    FROM up u
    JOIN categories c ON c.category_id = (SELECT parent_category_id
                                          FROM categories
                                          WHERE category_id = u.ancestor_id)
)
SELECT
    c.category_id                AS category_id,
    c.category_name              AS category_name,     -- лист
    root.ancestor_name           AS top_category,      -- корень ветки
    root.ancestor_id             AS top_category_id,
    c.category_level             AS category_level
FROM categories c
JOIN up root
  ON root.category_id = c.category_id
 AND root.ancestor_level = 1;                          -- оставляем только корень

-- ---------------------------------------------------------------------
-- v_order_lines — канонический факт-стол уровня ПОЗИЦИИ заказа.
--
-- Денежные определения (важно, дальше везде используются именно они):
--   gross_revenue = quantity * unit_price                — до скидки
--   net_revenue   = quantity * unit_price * (1 - disc)   — выручка «в кассу»
--   cogs          = quantity * unit_cost                 — себестоимость
--                   (снимок на момент заказа, не текущая цена поставщика)
--   gross_profit  = net_revenue - cogs
--   refund_amount = сумма возвратов по этой позиции (0, если возврата не было)
--   contribution  = gross_profit - refund_amount         — вклад после возвратов
--
-- ОТМЕНЁННЫЕ ЗАКАЗЫ ИСКЛЮЧЕНЫ ЗДЕСЬ. Это единственное место, где
-- принимается это решение, поэтому забыть про него в отдельном запросе
-- физически нельзя.
-- ---------------------------------------------------------------------
CREATE VIEW v_order_lines AS
SELECT
    oi.order_item_id,
    oi.order_id,
    o.customer_id,
    o.order_ts,
    substr(o.order_ts, 1, 7)                        AS order_month,
    o.status,
    o.channel                                       AS order_channel,
    o.device                                        AS order_device,
    o.ship_country,
    o.promo_code,
    oi.product_id,
    p.product_name,
    ct.category_name                                AS leaf_category,
    ct.top_category,
    oi.quantity,
    oi.unit_price,
    oi.unit_cost,
    oi.discount_pct,
    oi.quantity * oi.unit_price                                       AS gross_revenue,
    oi.quantity * oi.unit_price * (1 - oi.discount_pct)               AS net_revenue,
    oi.quantity * oi.unit_cost                                        AS cogs,
    oi.quantity * (oi.unit_price * (1 - oi.discount_pct) - oi.unit_cost) AS gross_profit,
    COALESCE(r.refund_amount, 0)                                      AS refund_amount,
    COALESCE(r.returned_qty, 0)                                       AS returned_qty,
      oi.quantity * (oi.unit_price * (1 - oi.discount_pct) - oi.unit_cost)
    - COALESCE(r.refund_amount, 0)                                    AS contribution
FROM order_items oi
JOIN orders   o  ON o.order_id   = oi.order_id
JOIN products p  ON p.product_id = oi.product_id
JOIN v_category_tree ct ON ct.category_id = p.category_id
LEFT JOIN (
    -- по одной позиции может быть несколько возвратов -> сворачиваем заранее,
    -- иначе join размножит строки и выручка задвоится
    SELECT order_item_id,
           SUM(refund_amount)     AS refund_amount,
           SUM(quantity_returned) AS returned_qty
    FROM order_returns
    GROUP BY order_item_id
) r ON r.order_item_id = oi.order_item_id
WHERE o.status <> 'cancelled';

-- ---------------------------------------------------------------------
-- v_orders_enriched — уровень ЗАКАЗА. Доставка вычитается здесь, а не в
-- v_order_lines: shipping_cost относится к заказу целиком, и размазывать
-- его по позициям значило бы придумывать несуществующую аллокацию.
-- ---------------------------------------------------------------------
CREATE VIEW v_orders_enriched AS
SELECT
    o.order_id,
    o.customer_id,
    o.order_ts,
    substr(o.order_ts, 1, 7)              AS order_month,
    o.status,
    o.channel,
    o.device,
    o.ship_country,
    o.promo_code,
    o.shipping_cost,
    COUNT(l.order_item_id)                AS n_lines,
    SUM(l.quantity)                       AS n_units,
    SUM(l.net_revenue)                    AS order_revenue,
    SUM(l.cogs)                           AS order_cogs,
    SUM(l.gross_profit)                   AS order_gross_profit,
    SUM(l.refund_amount)                  AS order_refunds,
    SUM(l.contribution) - o.shipping_cost AS order_contribution
FROM orders o
JOIN v_order_lines l ON l.order_id = o.order_id
GROUP BY o.order_id;

-- ---------------------------------------------------------------------
-- v_customer_cohort — когорта клиента.
--
-- Когорта = месяц ПЕРВОГО оплаченного заказа (не месяц регистрации:
-- зарегистрировавшийся, но не купивший клиент не участвует в retention).
-- cohort_idx — сквозной номер месяца, чтобы вычитать месяцы обычным
-- минусом, не связываясь с календарной арифметикой в каждом запросе.
-- ---------------------------------------------------------------------
CREATE VIEW v_customer_cohort AS
SELECT
    c.customer_id,
    c.acquisition_channel,
    c.country,
    c.region,
    c.first_device,
    f.first_order_ts,
    substr(f.first_order_ts, 1, 7)                          AS cohort_month,
    CAST(strftime('%Y', f.first_order_ts) AS INTEGER) * 12
  + CAST(strftime('%m', f.first_order_ts) AS INTEGER)       AS cohort_idx,
    f.orders_lifetime,
    f.revenue_lifetime
FROM customers c
JOIN (
    SELECT customer_id,
           MIN(order_ts)              AS first_order_ts,
           COUNT(DISTINCT order_id)   AS orders_lifetime,
           SUM(order_revenue)         AS revenue_lifetime
    FROM v_orders_enriched
    GROUP BY customer_id
) f ON f.customer_id = c.customer_id;

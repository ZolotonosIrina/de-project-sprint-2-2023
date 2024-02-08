-- DDL витрины данных
DROP TABLE IF EXISTS dwh.customer_report_datamart;

create table if not exists dwh.customer_report_datamart
(
    id bigint generated always as identity
        constraint customer_report_datamart_pk
            primary key,
    customer_id                 bigint         not null,
    customer_name              varchar        not null,
    customer_address           varchar        not null,
    customer_birthday          date           not null,
    customer_email             varchar        not null,
    customer_spent_money             numeric(15, 2) not null,
    platform_money              bigint         not null,
    count_order                 bigint         not null,
    avg_price_order             numeric(10, 2) not null,
    median_time_order_completed numeric(10, 1),
    top_product_category        varchar        not null,
    top_craftsman_id            bigint        not null,
    count_order_created         bigint         not null,
    count_order_in_progress     bigint         not null,
    count_order_delivery        bigint         not null,
    count_order_done            bigint         not null,
    count_order_not_done        bigint         not null,
    report_period               varchar        not null
);

-- DDL таблицы инкрементальных загрузок
DROP TABLE IF EXISTS dwh.load_dates_customer_report_datamart;

CREATE TABLE IF NOT EXISTS dwh.load_dates_customer_report_datamart (
    id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    load_dttm DATE NOT NULL,
    CONSTRAINT load_dates_customer_report_datamart_pk PRIMARY KEY (id)
);

WITH dwh_delta AS ( -- определяем, какие данные были изменены в витрине или добавлены в DWH. Формируем дельту изменений
    SELECT
        dcs.customer_id AS customer_id,
        dcs.customer_name AS customer_name,
        dcs.customer_address AS customer_address,
        dcs.customer_birthday AS customer_birthday,
        dcs.customer_email AS customer_email,
        dc.craftsman_id AS craftsman_id,
        fo.order_id AS order_id,
        dp.product_id AS product_id,
        dp.product_price AS product_price,
        dp.product_type AS product_type,
        fo.order_completion_date - fo.order_created_date AS diff_order_date,
        fo.order_status AS order_status,
        TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
        crd.customer_id AS exist_customer_id,
        dc.load_dttm AS craftsman_load_dttm,
        dcs.load_dttm AS customers_load_dttm,
        dp.load_dttm AS products_load_dttm
    FROM dwh.f_order fo
        INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id
        INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id
        INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
        LEFT JOIN dwh.customer_report_datamart crd ON dcs.customer_id = crd.customer_id
    WHERE
        (fo.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
        (dc.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
        (dcs.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart)) OR
        (dp.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_customer_report_datamart))
    ),
    dwh_update_delta AS ( -- делаем выборку заказчиков, по которым были изменения в DWH.
        SELECT
            dd.exist_customer_id AS customer_id
        FROM dwh_delta dd
        WHERE dd.exist_customer_id IS NOT NULL
    ),
    dwh_delta_insert_result AS ( -- делаем расчёт витрины по новым данным.
        SELECT
            T2.customer_id AS customer_id,
            T2.customer_name AS customer_name,
            T2.customer_address AS customer_address,
            T2.customer_birthday AS customer_birthday,
            T2.customer_email AS customer_email,
            T2.customer_spent_money AS customer_spent_money,
            T2.platform_money AS platform_money,
            T2.count_order AS count_order,
            T2.avg_price_order AS avg_price_order,
            T3.product_type AS top_product_category,
            T4.craftsman_id AS top_craftsman_id,
            T2.median_time_order_completed AS median_time_order_completed,
            T2.count_order_created AS count_order_created,
            T2.count_order_in_progress AS count_order_in_progress,
            T2.count_order_delivery AS count_order_delivery,
            T2.count_order_done AS count_order_done,
            T2.count_order_not_done AS count_order_not_done,
            T2.report_period AS report_period
        FROM (SELECT -- в этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, кроме столбца с самой популярной категорией товаров у мастера. Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN
                T1.customer_id AS customer_id,
                T1.customer_name AS customer_name,
                T1.customer_address AS customer_address,
                T1.customer_birthday AS customer_birthday,
                T1.customer_email AS customer_email,
                SUM(T1.product_price) AS customer_spent_money,
                SUM(T1.product_price) * 0.1 AS platform_money,
                COUNT(order_id) AS count_order,
                AVG(T1.product_price) AS avg_price_order,
                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress,
                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery,
                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done,
                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                T1.report_period AS report_period
            FROM dwh_delta AS T1
            WHERE T1.exist_customer_id IS NULL
            GROUP BY T1.customer_id, T1.customer_name, T1.customer_address, T1.customer_birthday, T1.customer_email, T1.report_period
        ) AS T2
            INNER JOIN  -- Эта выборка поможет определить самый популярный товар у заказчика.
                     (SELECT customer_id, product_type
                      FROM
                         (SELECT
                            dd.customer_id,
                            dd.product_type,
                            RANK() OVER(PARTITION BY dd.customer_id ORDER BY COUNT(product_id) DESC) AS rank_count_product
                            FROM dwh_delta AS dd
                        GROUP BY dd.customer_id, dd.product_type) T31
                      WHERE rank_count_product = 1) AS T3 ON T2.customer_id = T3.customer_id
            INNER JOIN  -- Эта выборка поможет определить самого популярного мастера у заказчика.
                     (SELECT customer_id, craftsman_id
                      FROM
                         (SELECT
                            dd.customer_id,
                            dd.craftsman_id,
                            RANK() OVER(PARTITION BY dd.customer_id ORDER BY COUNT(order_id) DESC) AS rank_count_order_by_craftsman
                            FROM dwh_delta AS dd
                        GROUP BY dd.customer_id, dd.craftsman_id) T41
                      WHERE rank_count_order_by_craftsman = 1) AS T4 ON T2.customer_id = T4.customer_id
            ORDER BY report_period),
    dwh_delta_update_result AS ( -- делаем перерасчёт для существующих записей витрины.
        SELECT
            T2.customer_id AS customer_id,
            T2.customer_name AS customer_name,
            T2.customer_address AS customer_address,
            T2.customer_birthday AS customer_birthday,
            T2.customer_email AS customer_email,
            T2.customer_spent_money AS customer_spent_money,
            T2.platform_money AS platform_money,
            T2.count_order AS count_order,
            T2.avg_price_order AS avg_price_order,
            T3.product_type AS top_product_category,
            T4.craftsman_id AS top_craftsman_id,
            T2.median_time_order_completed AS median_time_order_completed,
            T2.count_order_created AS count_order_created,
            T2.count_order_in_progress AS count_order_in_progress,
            T2.count_order_delivery AS count_order_delivery,
            T2.count_order_done AS count_order_done,
            T2.count_order_not_done AS count_order_not_done,
            T2.report_period AS report_period
        FROM (
            SELECT
                                 T1.customer_id AS customer_id,
                                 T1.customer_name AS customer_name,
                                 T1.customer_address AS customer_address,
                                 T1.customer_birthday AS customer_birthday,
                                 T1.customer_email AS customer_email,
                                 SUM(T1.product_price) AS customer_spent_money,
                                 SUM(T1.product_price) * 0.1 AS platform_money,
                                 COUNT(order_id) AS count_order,
                                 AVG(T1.product_price) AS avg_price_order,
                                 PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                 SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                                 SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress,
                                 SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery,
                                 SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done,
                                 SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                 T1.report_period AS report_period
                          FROM (
                                   SELECT     -- в этой выборке достаём из DWH обновлённые или новые данные по заказчикам, которые уже есть в витрине
                                              dcs.customer_id AS customer_id,
                                              dcs.customer_name AS customer_name,
                                              dcs.customer_address AS customer_address,
                                              dcs.customer_birthday AS customer_birthday,
                                              dcs.customer_email AS customer_email,
                                              fo.order_id AS order_id,
                                              dp.product_id AS product_id,
                                              dp.product_price AS product_price,
                                              dp.product_type AS product_type,
                                              fo.order_completion_date - fo.order_created_date AS diff_order_date,
                                              fo.order_status AS order_status,
                                              TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period
                                   FROM dwh.f_order fo
                                            INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id
                                            INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                                            INNER JOIN dwh_update_delta ud ON fo.customer_id = ud.customer_id
                               ) AS T1
                          GROUP BY T1.customer_id, T1.customer_name, T1.customer_address, T1.customer_birthday, T1.customer_email, T1.report_period
                      ) AS T2
                INNER JOIN  -- Эта выборка поможет определить самый популярный товар у заказчика.
                     (SELECT customer_id, product_type
                      FROM
                          (SELECT
                               dd.customer_id,
                               dd.product_type,
                               RANK() OVER(PARTITION BY dd.customer_id ORDER BY COUNT(product_id) DESC) AS rank_count_product
                           FROM dwh_delta AS dd
                           GROUP BY dd.customer_id, dd.product_type) T31
                      WHERE rank_count_product = 1) AS T3 ON T2.customer_id = T3.customer_id
                INNER JOIN  -- Эта выборка поможет определить самого популярного мастера у заказчика.
                     (SELECT customer_id, craftsman_id
                      FROM
                          (SELECT
                               dd.customer_id,
                               dd.craftsman_id,
                               RANK() OVER(PARTITION BY dd.customer_id ORDER BY COUNT(order_id) DESC) AS rank_count_order_by_craftsman
                           FROM dwh_delta AS dd
                           GROUP BY dd.customer_id, dd.craftsman_id) T41
                      WHERE rank_count_order_by_craftsman = 1) AS T4 ON T2.customer_id = T4.customer_id
                 ORDER BY report_period
    ),
    insert_delta AS ( -- выполняем insert новых расчитанных данных для витрины
        INSERT INTO dwh.customer_report_datamart (
                                                   customer_id,
                                                   customer_name,
                                                   customer_address,
                                                   customer_birthday,
                                                   customer_email,
                                                   customer_spent_money,
                                                   platform_money,
                                                   count_order,
                                                   avg_price_order,
                                                   median_time_order_completed,
                                                   top_product_category,
                                                   top_craftsman_id,
                                                   count_order_created,
                                                   count_order_in_progress,
                                                   count_order_delivery,
                                                   count_order_done,
                                                   count_order_not_done,
                                                   report_period
            ) SELECT
                    customer_id,
                    customer_name,
                    customer_address,
                    customer_birthday,
                    customer_email,
                    customer_spent_money,
                    platform_money,
                    count_order,
                    avg_price_order,
                    median_time_order_completed,
                    top_product_category,
                    top_craftsman_id,
                    count_order_created,
                    count_order_in_progress,
                    count_order_delivery,
                    count_order_done,
                    count_order_not_done,
                    report_period
              FROM dwh_delta_insert_result
    ),
    update_delta AS ( -- выполняем обновление показателей в отчёте по уже существующим мастерам
        UPDATE dwh.customer_report_datamart SET
            customer_name = updates.customer_name,
            customer_address = updates.customer_address,
            customer_birthday = updates.customer_birthday,
            customer_email = updates.customer_email,
            customer_spent_money = updates.customer_spent_money,
            platform_money = updates.platform_money,
            count_order = updates.count_order,
            avg_price_order = updates.avg_price_order,
            median_time_order_completed = updates.median_time_order_completed,
            top_product_category = updates.top_product_category,
            top_craftsman_id = updates.top_craftsman_id,
            count_order_created = updates.count_order_created,
            count_order_in_progress = updates.count_order_in_progress,
            count_order_delivery = updates.count_order_delivery,
            count_order_done = updates.count_order_done,
            count_order_not_done = updates.count_order_not_done,
            report_period = updates.report_period
            FROM (
                SELECT
                    customer_id,
                    customer_name,
                    customer_address,
                    customer_birthday,
                    customer_email,
                    customer_spent_money,
                    platform_money,
                    count_order,
                    avg_price_order,
                    median_time_order_completed,
                    top_product_category,
                    top_craftsman_id,
                    count_order_created,
                    count_order_in_progress,
                    count_order_delivery,
                    count_order_done,
                    count_order_not_done,
                    report_period
                FROM dwh_delta_update_result) AS updates
            WHERE dwh.customer_report_datamart.customer_id = updates.customer_id
    ),
    insert_load_date AS ( -- делаем запись в таблицу загрузок о том, когда была совершена загрузка, чтобы в следующий раз взять данные, которые будут добавлены или изменены после этой даты
        INSERT INTO dwh.load_dates_customer_report_datamart (
                                                              load_dttm
            )
            SELECT GREATEST(COALESCE(MAX(craftsman_load_dttm), NOW()),
                            COALESCE(MAX(customers_load_dttm), NOW()),
                            COALESCE(MAX(products_load_dttm), NOW()))
            FROM dwh_delta
    )
SELECT 'increment datamart'; -- инициализируем запрос CTE
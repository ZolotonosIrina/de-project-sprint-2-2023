drop table if exists dwh.customer_report_datamart;

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
    top_craftsman               varchar        not null,
    count_order_created         bigint         not null,
    count_order_in_progress     bigint         not null,
    count_order_delivery        bigint         not null,
    count_order_done            bigint         not null,
    count_order_not_done        bigint         not null,
    report_period               varchar        not null
);

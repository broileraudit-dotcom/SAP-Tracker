-- ========== أوامر إنتاج الدجاج اللاحم: الجداول والمشغّلات والعروض ==========
create type order_status as enum ('Opened','Start','In progress','Final review','Done');

create or replace function today_sa() returns date language sql stable as
$$ select (now() at time zone 'Asia/Riyadh')::date $$;

create table production_orders (
  order_no bigint primary key,
  farm text, farm_code text, house text,
  material text not null default 'Broiler',
  start_date date not null,
  end_date date,
  actual_finish_date date,
  housed_qty int, target_qty int, mortality int,
  status order_status not null default 'Opened',
  notes text,
  created_at timestamptz default now()
);

create table operations (            -- كل صف = يوم تشغيل (Operation)
  id bigserial primary key,
  order_no bigint not null references production_orders(order_no) on delete cascade,
  day_no int not null,
  op_date date not null,             -- موعد استحقاق المهمتين
  confirmation_at date,              -- تاريخ تأكيد الإنتاجية الفعلي (null = لم تنفذ)
  inspection_at date,                -- تاريخ تسجيل الفحوصات الفعلي
  unique (order_no, day_no)
);
create index on operations(order_no);
create index on operations(op_date);

-- نهاية الأمر = تاريخ البدء + 29، ثم تُنشأ 29 يوماً تلقائياً
create function trg_order_before() returns trigger language plpgsql as $$
begin new.end_date := coalesce(new.end_date, new.start_date + 29); return new; end $$;
create trigger t_order_before before insert on production_orders
  for each row execute function trg_order_before();

create function trg_order_after() returns trigger language plpgsql as $$
begin
  if new.material = 'Broiler' then
    insert into operations(order_no, day_no, op_date)
    select new.order_no, d, new.start_date + d from generate_series(1,29) d;
  end if;
  return null;
end $$;
create trigger t_order_after after insert on production_orders
  for each row execute function trg_order_after();

-- عند إضافة/حذف يوم يُحدَّث تاريخ نهاية الأمر تلقائياً
create function trg_ops_end() returns trigger language plpgsql as $$
declare n bigint := case when tg_op = 'DELETE' then old.order_no else new.order_no end;
begin
  update production_orders set end_date = (select max(op_date) from operations where order_no = n)
  where order_no = n and exists (select 1 from operations where order_no = n);
  return null;
end $$;
create trigger t_ops_end after insert or delete on operations
  for each row execute function trg_ops_end();

-- كل مهمة على حدة (تأكيد إنتاجية / تسجيل فحوصات) مع حالتها ومدة التأخير
create view v_tasks with (security_invoker = true) as
with x as (
  select id op_id, order_no, day_no, op_date, 'Confirmation'::text task, confirmation_at done_at from operations
  union all
  select id, order_no, day_no, op_date, 'Inspection', inspection_at from operations)
select x.*, o.farm, o.farm_code, o.house, o.status order_status,
  case when done_at is not null then case when done_at <= op_date then 'on_time' else 'late' end
       when op_date < today_sa() then 'overdue'
       when op_date = today_sa() then 'due_today' else 'upcoming' end as state,
  case when done_at is not null then greatest(done_at - op_date, 0)
       else greatest(today_sa() - op_date, 0) end as delay_days
from x join production_orders o on o.order_no = x.order_no;

create view v_order_summary with (security_invoker = true) as
select o.*,
  count(t.task) as tasks_total,
  count(*) filter (where t.state in ('on_time','late')) as tasks_done,
  count(*) filter (where t.state = 'overdue') as tasks_overdue,
  count(*) filter (where t.state = 'due_today') as tasks_due_today,
  count(*) filter (where t.state = 'on_time') as tasks_on_time,
  count(*) filter (where t.state = 'late') as tasks_late,
  coalesce(max(t.delay_days) filter (where t.state = 'overdue'), 0) as max_delay
from production_orders o left join v_tasks t on t.order_no = o.order_no
group by o.order_no;

-- الأمان: المستخدمون المسجلون فقط
alter table production_orders enable row level security;
alter table operations enable row level security;
create policy "auth all" on production_orders for all to authenticated using (true) with check (true);
create policy "auth all" on operations for all to authenticated using (true) with check (true);

"""python tools/make_seed.py Production_Orders.xlsx > supabase/seed.sql"""
import sys, datetime as dt
from openpyxl import load_workbook
MAP = {'Opend':'Opened','Start':'Start','In progress':'In progress','Final review':'Final review','Done':'Done'}
ws = load_workbook(sys.argv[1], data_only=False)['Broiler Production']
q = lambda s: "'" + str(s).replace("'", "''") + "'" if s not in (None, '') else 'null'
rows = []
for r in ws.iter_rows(min_row=2, values_only=True):
    if not isinstance(r[0], (int, float)) or not isinstance(r[5], dt.datetime): continue
    housed = int(r[8]); fin = r[7] if isinstance(r[7], dt.datetime) else None
    rows.append("(%d,%s,%s,%s,'Broiler','%s',%s,%d,%d,%d,'%s')" % (
        r[0], q(str(r[1]).strip()), q(r[3]), q(str(r[2]).zfill(4)), r[5].date(),
        ("'%s'" % fin.date()) if fin else 'null', housed, round(housed*0.95), round(housed*0.06),
        MAP.get(r[14], 'Opened')))
print("-- مولَّد من ملف Production_Orders.xlsx (%d أمر)" % len(rows))
print("insert into production_orders(order_no,farm,farm_code,house,material,start_date,actual_finish_date,housed_qty,target_qty,mortality,status) values")
print(",\n".join(rows) + ";")
print("""
-- افتراض: الأوامر في مرحلة المراجعة النهائية/المغلقة نُفّذت مهامها كاملة في مواعيدها
update operations set confirmation_at = op_date, inspection_at = op_date
where order_no in (select order_no from production_orders where status in ('Final review','Done'));""")

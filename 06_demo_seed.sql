BEGIN;

INSERT INTO suppliers (supplier_name, contact_person, phone, license_number)
VALUES
    ('Apex Pharma Distributors', 'Rohan Mehta', '+91-9811100011', 'MG-DEMO-SUPPLIER-APEX'),
    ('MedCore Supply Co.', 'Priya Nair', '+91-9811100022', 'MG-DEMO-SUPPLIER-MEDCORE')
ON CONFLICT (license_number) DO NOTHING;

INSERT INTO medicines (medicine_name, manufacturer, category, unit_price)
VALUES
    ('Amoxicillin 500mg', 'Cipla', 'Antibiotic', 10.00),
    ('Paracetamol 650mg', 'GSK', 'Analgesic', 5.00)
ON CONFLICT (medicine_name, manufacturer) DO NOTHING;

INSERT INTO inventory_batches
    (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
SELECT m.medicine_id, s.supplier_id, 'MG-DEMO-AMX-EXPIRED',
       CURRENT_DATE - 180, CURRENT_DATE - 5, 30, 30
FROM medicines m
CROSS JOIN suppliers s
WHERE m.medicine_name = 'Amoxicillin 500mg'
  AND m.manufacturer = 'Cipla'
  AND s.license_number = 'MG-DEMO-SUPPLIER-APEX'
ON CONFLICT (medicine_id, batch_code) DO NOTHING;

INSERT INTO inventory_batches
    (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
SELECT m.medicine_id, s.supplier_id, 'MG-DEMO-AMX-30D',
       CURRENT_DATE - 150, CURRENT_DATE + 30, 25, 25
FROM medicines m
CROSS JOIN suppliers s
WHERE m.medicine_name = 'Amoxicillin 500mg'
  AND m.manufacturer = 'Cipla'
  AND s.license_number = 'MG-DEMO-SUPPLIER-APEX'
ON CONFLICT (medicine_id, batch_code) DO NOTHING;

INSERT INTO inventory_batches
    (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
SELECT m.medicine_id, s.supplier_id, 'MG-DEMO-AMX-31D',
       CURRENT_DATE - 120, CURRENT_DATE + 31, 20, 20
FROM medicines m
CROSS JOIN suppliers s
WHERE m.medicine_name = 'Amoxicillin 500mg'
  AND m.manufacturer = 'Cipla'
  AND s.license_number = 'MG-DEMO-SUPPLIER-APEX'
ON CONFLICT (medicine_id, batch_code) DO NOTHING;

INSERT INTO inventory_batches
    (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
SELECT m.medicine_id, s.supplier_id, 'MG-DEMO-AMX-180D',
       CURRENT_DATE - 30, CURRENT_DATE + 180, 50, 50
FROM medicines m
CROSS JOIN suppliers s
WHERE m.medicine_name = 'Amoxicillin 500mg'
  AND m.manufacturer = 'Cipla'
  AND s.license_number = 'MG-DEMO-SUPPLIER-MEDCORE'
ON CONFLICT (medicine_id, batch_code) DO NOTHING;

INSERT INTO inventory_batches
    (medicine_id, supplier_id, batch_code, manufacture_date, expiry_date, quantity_received, current_stock)
SELECT m.medicine_id, s.supplier_id, 'MG-DEMO-PARA-90D',
       CURRENT_DATE - 40, CURRENT_DATE + 90, 10, 10
FROM medicines m
CROSS JOIN suppliers s
WHERE m.medicine_name = 'Paracetamol 650mg'
  AND m.manufacturer = 'GSK'
  AND s.license_number = 'MG-DEMO-SUPPLIER-MEDCORE'
ON CONFLICT (medicine_id, batch_code) DO NOTHING;

COMMIT;

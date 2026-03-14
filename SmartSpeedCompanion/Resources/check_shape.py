import sqlite3

db_path = "c:/Users/madhu/SmartSpeedCompanion iOS CarPlay/SmartSpeedCompanion/Resources/HPMS_2024_Data_-2111065798425599378.geodatabase"
try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    row = cur.execute("SELECT SHAPE FROM SpeedLimit_2024 LIMIT 1").fetchone()
    if row and row[0]:
        print(f"Hex: {row[0].hex()[:128]}")
    conn.close()
except Exception as e:
    print(e)

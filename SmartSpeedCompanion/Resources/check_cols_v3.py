import sqlite3
db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()
cursor.execute("PRAGMA table_info(SpeedLimit_2024);")
cols = [c[1] for c in cursor.fetchall()]
print("SpeedLimit_2024 columns:", cols)
conn.close()

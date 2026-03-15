import sqlite3
db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()
cursor.execute("PRAGMA table_info(SpeedLimit_2024);")
for col in cursor.fetchall():
    if col[1] == "SpeedLimit":
        print(f"SpeedLimit type: {col[2]}")
conn.close()

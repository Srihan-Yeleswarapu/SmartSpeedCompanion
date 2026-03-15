import sqlite3
db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()
cursor.execute("PRAGMA table_info(st_spindex__SpeedLimit_2024_SHAPE);")
for col in cursor.fetchall():
    print(col)
conn.close()

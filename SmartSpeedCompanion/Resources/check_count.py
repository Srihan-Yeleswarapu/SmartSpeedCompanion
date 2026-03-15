import sqlite3
db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()
cursor.execute("SELECT COUNT(*) FROM SpeedLimit_2024;")
total = cursor.fetchone()[0]
cursor.execute("SELECT COUNT(*) FROM st_spindex__SpeedLimit_2024_SHAPE;")
indexed = cursor.fetchone()[0]
print(f"Total: {total}, Indexed: {indexed}")
conn.close()

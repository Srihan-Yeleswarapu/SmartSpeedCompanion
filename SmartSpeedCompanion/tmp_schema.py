import sqlite3
import sys

db_path = "Resources/HPMS_2024_Data_-2111065798425599378.geodatabase"
out_path = "schema_output.txt"
with open(out_path, "w") as f:
    try:
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()
        tables = [row[0] for row in cur.execute("SELECT name FROM sqlite_master WHERE type='table';").fetchall()]
        f.write("TABLES:\n")
        for t in tables:
            f.write(f"- {t}\n")
            
        for t in tables:
            if "hpms" in t.lower() or "speed" in t.lower() or "arizona" in t.lower() or "data" in t.lower():
                f.write(f"\nSCHEMA FOR {t}:\n")
                schema = cur.execute(f"PRAGMA table_info({t});").fetchall()
                for col in schema:
                    f.write(str(col) + "\n")
                    
    except Exception as e:
        f.write(f"Error: {e}\n")

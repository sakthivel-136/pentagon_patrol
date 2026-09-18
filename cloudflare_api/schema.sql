CREATE TABLE factories (
  factory_code TEXT PRIMARY KEY,
  factory_name TEXT NOT NULL,
  location TEXT,
  is_active INTEGER DEFAULT 1,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  factory_address TEXT
);

CREATE TABLE login_info (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL UNIQUE,
  user_pin TEXT NOT NULL,
  name TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('ADMIN', 'INDUSTRY_ENGINEER', 'MD', 'CEO')),
  is_active INTEGER DEFAULT 1,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE qr (
  qr_id INTEGER PRIMARY KEY AUTOINCREMENT,
  qr_name TEXT NOT NULL,
  lat REAL,
  lon REAL,
  status TEXT DEFAULT 'active',
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  factory_code TEXT,
  waiting_time INTEGER NOT NULL DEFAULT 15,
  FOREIGN KEY (factory_code) REFERENCES factories (factory_code)
);

CREATE TABLE report_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  report_type TEXT NOT NULL,
  factory_code TEXT NOT NULL,
  report_date TEXT NOT NULL,
  generated_by_user_id TEXT NOT NULL,
  generated_by_name TEXT,
  generated_by_role TEXT,
  generated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE scan_points (
  id TEXT PRIMARY KEY,
  factory_id TEXT,
  scan_point_name TEXT NOT NULL,
  scan_point_code TEXT,
  location TEXT,
  scan_type TEXT,
  floor TEXT,
  area TEXT,
  risk_level TEXT DEFAULT 'Low',
  is_active INTEGER DEFAULT 1,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (factory_id) REFERENCES factories(factory_code)
);

CREATE TABLE scanning_details (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guard_name TEXT,
  qr_id TEXT,
  qr_name TEXT,
  lat REAL,
  log REAL,
  scan_time DATETIME DEFAULT CURRENT_TIMESTAMP,
  status TEXT,
  factory_code TEXT,
  round_slot DATETIME,
  UNIQUE (factory_code, qr_id, round_slot)
);

CREATE TABLE security_users (
  security_id TEXT PRIMARY KEY,
  security_name TEXT NOT NULL,
  security_password TEXT NOT NULL,
  factory TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

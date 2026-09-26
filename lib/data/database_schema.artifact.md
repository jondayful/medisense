# MediSense Database Schema (SQLite)

This schema follows high-standard database design principles focusing on normalization, validation, and performance.

## 🗃️ Normalized Tables

### 1. `medications`
Stores the core medication definitions.
- **Normalization**: Only static medication attributes.
- **Flexibility Handling**: Booleans stored as `INTEGER` (0/1), dates as `ISO8601` or `Unix Timestamps`.

| Column | Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| `id` | TEXT | PRIMARY KEY | Unique UUID string |
| `name` | TEXT | NOT NULL, CHECK > 0 | Medication name |
| `dosage` | TEXT | NOT NULL | e.g., "500mg" |
| `form` | TEXT | NOT NULL | e.g., "Tablet" |
| `color_hex` | TEXT | NOT NULL | Hex color for UI consistency |
| `expiration_date` | TEXT | - | ISO8601 date string |
| `created_at` | INTEGER | NOT NULL | Metadata: Unix Timestamp |
| `is_active` | INTEGER | DEFAULT 1 | Soft delete support |

### 2. `schedules`
Stores the recurring times for each medication.
- **Normalization**: One-to-many relationship with `medications`.

| Column | Type | Constraints | Description |
| :--- | :--- | :--- | :--- |
| `id` | TEXT | PRIMARY KEY | Unique ID |
| `medication_id` | TEXT | FOREIGN KEY | Refers to `medications.id` |
| `hour` | INTEGER | CHECK (0-23) | 24h format validation |
| `minute` | INTEGER | CHECK (0-59) | Minute validation |

### 3. `adherence_logs`
Tracks the history of taken/missed doses.
- **Performance**: Heavy use of indices for reporting.
- **Metadata**: Detailed timestamping for every action.

## 🚀 Performance Optimizations
- **Indices**: Created on `timestamp` and `medication_id` to ensure dashboard queries (like weekly adherence) remain fast as the data grows.
- **Foreign Keys**: Enabled `PRAGMA foreign_keys = ON` to prevent orphaned records.

## ✅ Data Validation
- **CHECK Constraints**: SQL-level validation for hour ranges and non-empty strings.
- **Conflict Strategy**: `REPLACE` for updates, ensuring unique integrity.

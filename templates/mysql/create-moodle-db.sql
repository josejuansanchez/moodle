-- =============================================================================
--  Base de datos y usuario de Moodle
--  Plantilla: los scripts sustituyen DB_NAME, DB_USER y DB_PASS con envsubst.
--
--  Buenas prácticas:
--    - utf8mb4: juego de caracteres completo (acentos, emojis...)
--    - el usuario de Moodle solo tiene permisos sobre SU base de datos y solo
--      los que Moodle necesita (no es administrador de MySQL)
-- =============================================================================

CREATE DATABASE IF NOT EXISTS ${DB_NAME}
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, CREATE TEMPORARY TABLES,
      DROP, INDEX, ALTER
  ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';

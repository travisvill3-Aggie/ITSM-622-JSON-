#!/bin/bash

# ---------------------------------------------------------------------------
# On my honor, as an Aggie, I have neither given nor received unauthorized
# assistance on this assignment. I further affirm that I have not and will not
# provide this code to any person, platform, or repository without the express
# written permission of Dr. Gomillion. I understand that any violation of these
# standards will have serious repercussions.
# ---------------------------------------------------------------------------

# ==============================================================================
# ISTM 622 – JSON Milestone
# Automated User-Data Script
# Installs MariaDB, rebuilds POS, and generates:
#   /var/lib/mysql-files/prod.json
#   /var/lib/mysql-files/cust.json
#   /var/lib/mysql-files/custom1.json
#   /var/lib/mysql-files/custom2.json
# ==============================================================================

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
export DEBIAN_FRONTEND=noninteractive
set -euo pipefail

# ========================
# VARIABLES
# ========================
LINUX_USER="tvillanueva"
UIN="529004769"
DATA_URL="https://622.gomillion.org/data/${UIN}.zip"
HOME_DIR="/home/${LINUX_USER}"

echo "### Starting ISTM 622 JSON Milestone automation ###"

# ========================
# SYSTEM UPDATE
# ========================
apt-get update -y
apt-get upgrade -y
apt-get install -y curl unzip wget gnupg2 ca-certificates lsb-release apt-transport-https

# ========================
# INSTALL MARIADB 11.8
# ========================
mkdir -p /etc/apt/keyrings
curl -LsS https://mariadb.org/mariadb_release_signing_key.pgp \
  | gpg --dearmor -o /etc/apt/keyrings/mariadb.gpg

cat > /etc/apt/sources.list.d/mariadb.list <<EOF
deb [signed-by=/etc/apt/keyrings/mariadb.gpg] https://deb.mariadb.org/11.8/ubuntu noble main
EOF

apt-get update -y
apt-get install -y mariadb-server

# ========================
# MARIADB CONFIG
# ========================
mkdir -p /var/lib/mysql-files
chown mysql:mysql /var/lib/mysql-files
chmod 750 /var/lib/mysql-files

cat > /etc/mysql/mariadb.conf.d/99-istm622.cnf <<EOF
[mysqld]
local_infile=1
secure_file_priv=/var/lib/mysql-files
EOF

systemctl enable mariadb
systemctl restart mariadb
sleep 5

# ========================
# CREATE LINUX USER
# ========================
id -u "${LINUX_USER}" &>/dev/null || useradd -m -s /bin/bash "${LINUX_USER}"

# ========================
# DOWNLOAD SOURCE DATA
# ========================
echo "### Downloading source data zip ###"
sudo -u "${LINUX_USER}" wget -O "${HOME_DIR}/${UIN}.zip" "${DATA_URL}"

if [ ! -s "${HOME_DIR}/${UIN}.zip" ]; then
  echo "ERROR: Download failed or zip is empty."
  exit 1
fi

echo "### Unzipping source data ###"
sudo -u "${LINUX_USER}" unzip -o "${HOME_DIR}/${UIN}.zip" -d "${HOME_DIR}"

# ========================
# WRITE etl.sql
# ========================
cat > "${HOME_DIR}/etl.sql" <<'EOF'
DROP DATABASE IF EXISTS POS;
CREATE DATABASE POS;
USE POS;

CREATE TABLE City (
  zip   DECIMAL(5,0) ZEROFILL PRIMARY KEY,
  city  VARCHAR(32),
  state VARCHAR(4)
) ENGINE=InnoDB;

CREATE TABLE Customer (
  id        SERIAL PRIMARY KEY,
  firstName VARCHAR(32),
  lastName  VARCHAR(30),
  email     VARCHAR(128),
  address1  VARCHAR(100),
  address2  VARCHAR(50),
  phone     VARCHAR(32),
  birthdate DATE,
  zip       DECIMAL(5,0) ZEROFILL,
  CONSTRAINT fk_customer_city FOREIGN KEY (zip) REFERENCES City(zip)
) ENGINE=InnoDB;

CREATE TABLE Product (
  id                SERIAL PRIMARY KEY,
  name              VARCHAR(128),
  currentPrice      DECIMAL(6,2),
  availableQuantity INT
) ENGINE=InnoDB;

CREATE TABLE `Order` (
  id          SERIAL PRIMARY KEY,
  datePlaced  DATE,
  dateShipped DATE,
  customer_id BIGINT UNSIGNED,
  CONSTRAINT fk_order_customer FOREIGN KEY (customer_id) REFERENCES Customer(id)
) ENGINE=InnoDB;

CREATE TABLE Orderline (
  order_id   BIGINT UNSIGNED,
  product_id BIGINT UNSIGNED,
  quantity   INT,
  PRIMARY KEY (order_id, product_id),
  CONSTRAINT fk_orderline_order   FOREIGN KEY (order_id)   REFERENCES `Order`(id),
  CONSTRAINT fk_orderline_product FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE PriceHistory (
  id         SERIAL PRIMARY KEY,
  oldPrice   DECIMAL(6,2),
  newPrice   DECIMAL(6,2),
  ts         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  product_id BIGINT UNSIGNED,
  CONSTRAINT fk_pricehistory_product FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE staging_customer (
  ID VARCHAR(50),
  FN VARCHAR(255),
  LN VARCHAR(255),
  CT VARCHAR(255),
  ST VARCHAR(255),
  ZP VARCHAR(50),
  S1 VARCHAR(255),
  S2 VARCHAR(255),
  EM VARCHAR(255),
  BD VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orders (
  OID     VARCHAR(50),
  CID     VARCHAR(50),
  Ordered VARCHAR(50),
  Shipped VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orderlines (
  OID VARCHAR(50),
  PID VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_products (
  ID             VARCHAR(50),
  Name           VARCHAR(255),
  Price          VARCHAR(50),
  QuantityOnHand VARCHAR(50)
) ENGINE=InnoDB;

LOAD DATA LOCAL INFILE '/home/tvillanueva/customers.csv'
INTO TABLE staging_customer
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/tvillanueva/orders.csv'
INTO TABLE staging_orders
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/tvillanueva/orderlines.csv'
INTO TABLE staging_orderlines
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/tvillanueva/products.csv'
INTO TABLE staging_products
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@ID, @Name, @Price, @QOH)
SET
  ID = @ID,
  Name = @Name,
  Price = @Price,
  QuantityOnHand = @QOH;

INSERT IGNORE INTO City (zip, city, state)
SELECT DISTINCT
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED) AS zip,
  CT AS city,
  ST AS state
FROM staging_customer
WHERE NULLIF(ZP,'') IS NOT NULL;

INSERT INTO Customer (id, firstName, lastName, email, address1, address2, phone, birthdate, zip)
SELECT
  CAST(ID AS UNSIGNED),
  FN,
  LN,
  NULLIF(EM,''),
  NULLIF(S1,''),
  NULLIF(S2,''),
  NULL,
  STR_TO_DATE(NULLIF(BD,''), '%m/%d/%Y'),
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED)
FROM staging_customer;

INSERT INTO Product (id, name, currentPrice, availableQuantity)
SELECT
  CAST(ID AS UNSIGNED),
  Name,
  CAST(REPLACE(REPLACE(NULLIF(Price,''), '$', ''), ',', '') AS DECIMAL(6,2)),
  CAST(NULLIF(QuantityOnHand,'') AS UNSIGNED)
FROM staging_products;

INSERT INTO `Order` (id, datePlaced, dateShipped, customer_id)
SELECT
  CAST(OID AS UNSIGNED),
  CASE
    WHEN NULLIF(Ordered,'') IS NULL THEN NULL
    WHEN LOWER(Ordered) = 'cancelled' THEN NULL
    ELSE DATE(STR_TO_DATE(Ordered, '%Y-%m-%d %H:%i:%s'))
  END,
  CASE
    WHEN NULLIF(Shipped,'') IS NULL THEN NULL
    WHEN LOWER(Shipped) = 'cancelled' THEN NULL
    ELSE DATE(STR_TO_DATE(Shipped, '%Y-%m-%d %H:%i:%s'))
  END,
  CAST(CID AS UNSIGNED)
FROM staging_orders;

INSERT INTO Orderline (order_id, product_id, quantity)
SELECT
  CAST(OID AS UNSIGNED),
  CAST(PID AS UNSIGNED),
  COUNT(*) AS quantity
FROM staging_orderlines
GROUP BY CAST(OID AS UNSIGNED), CAST(PID AS UNSIGNED);

DROP TABLE staging_customer;
DROP TABLE staging_orders;
DROP TABLE staging_orderlines;
DROP TABLE staging_products;
EOF

# ========================
# WRITE views.sql
# ========================
cat > "${HOME_DIR}/views.sql" <<'EOF'
SOURCE etl.sql;
USE POS;

DROP VIEW IF EXISTS v_ProductBuyers;
CREATE VIEW v_ProductBuyers AS
SELECT
  p.id   AS productID,
  p.name AS productName,
  IFNULL(
    GROUP_CONCAT(
      DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
      ORDER BY c.id
      SEPARATOR ', '
    ),
    ''
  ) AS customers
FROM Product p
LEFT JOIN Orderline ol
  ON ol.product_id = p.id
LEFT JOIN `Order` o
  ON o.id = ol.order_id
LEFT JOIN Customer c
  ON c.id = o.customer_id
GROUP BY p.id, p.name
ORDER BY p.id;

DROP TABLE IF EXISTS mv_ProductBuyers;
CREATE TABLE mv_ProductBuyers AS
SELECT * FROM v_ProductBuyers;

ALTER TABLE mv_ProductBuyers
  ADD INDEX idx_mv_productbuyers_productID (productID);

DROP TRIGGER IF EXISTS trg_orderline_ai_mv_productbuyers;
DROP TRIGGER IF EXISTS trg_orderline_ad_mv_productbuyers;
DROP TRIGGER IF EXISTS trg_product_bu_pricehistory;

DELIMITER $$

CREATE TRIGGER trg_orderline_ai_mv_productbuyers
AFTER INSERT ON Orderline
FOR EACH ROW
BEGIN
  UPDATE mv_ProductBuyers
  SET
    productName = (SELECT p.name FROM Product p WHERE p.id = NEW.product_id),
    customers = IFNULL((
      SELECT GROUP_CONCAT(
               DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
               ORDER BY c.id
               SEPARATOR ', '
             )
      FROM Orderline ol
      JOIN `Order` o  ON o.id = ol.order_id
      JOIN Customer c ON c.id = o.customer_id
      WHERE ol.product_id = NEW.product_id
    ), '')
  WHERE productID = NEW.product_id;
END$$

CREATE TRIGGER trg_orderline_ad_mv_productbuyers
AFTER DELETE ON Orderline
FOR EACH ROW
BEGIN
  UPDATE mv_ProductBuyers
  SET
    productName = (SELECT p.name FROM Product p WHERE p.id = OLD.product_id),
    customers = IFNULL((
      SELECT GROUP_CONCAT(
               DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
               ORDER BY c.id
               SEPARATOR ', '
             )
      FROM Orderline ol
      JOIN `Order` o  ON o.id = ol.order_id
      JOIN Customer c ON c.id = o.customer_id
      WHERE ol.product_id = OLD.product_id
    ), '')
  WHERE productID = OLD.product_id;
END$$

CREATE TRIGGER trg_product_bu_pricehistory
BEFORE UPDATE ON Product
FOR EACH ROW
BEGIN
  IF NOT (NEW.currentPrice <=> OLD.currentPrice) THEN
    INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
    VALUES (OLD.currentPrice, NEW.currentPrice, OLD.id);
  END IF;
END$$

DELIMITER ;
EOF

# ========================
# WRITE json.sql
# ========================
cat > "${HOME_DIR}/json.sql" <<'EOF'
USE POS;

-- ============================================================
-- CASE 1: Product Details View
-- prod.json
-- ============================================================
SELECT JSON_OBJECT(
  'ProductID', p.id,
  'currentPrice', p.currentPrice,
  'productName', p.name,
  'customers',
    COALESCE(
      (
        SELECT JSON_ARRAYAGG(
                 JSON_OBJECT(
                   'CustomerID', x.id,
                   'CustomerName', CONCAT(x.firstName, ' ', x.lastName)
                 )
               )
        FROM (
          SELECT DISTINCT c.id, c.firstName, c.lastName
          FROM Orderline ol
          JOIN `Order` o ON o.id = ol.order_id
          JOIN Customer c ON c.id = o.customer_id
          WHERE ol.product_id = p.id
        ) AS x
      ),
      JSON_ARRAY()
    )
)
FROM Product p
ORDER BY p.id
INTO OUTFILE '/var/lib/mysql-files/prod.json'
FIELDS TERMINATED BY ''
ESCAPED BY ''
LINES TERMINATED BY '\n';

-- ============================================================
-- CASE 2: Customer Dashboard
-- cust.json
-- ============================================================
SELECT JSON_OBJECT(
  'CustomerID', c.id,
  'customer_name', CONCAT(c.firstName, ' ', c.lastName),
  'printed_address_1',
    CASE
      WHEN c.address2 IS NULL OR c.address2 = '' THEN c.address1
      ELSE CONCAT(c.address1, ' #', c.address2)
    END,
  'printed_address_2',
    CONCAT(ci.city, ', ', ci.state, '   ', LPAD(ci.zip, 5, '0')),
  'orders',
    COALESCE(
      (
        SELECT JSON_ARRAYAGG(
                 JSON_OBJECT(
                   'OrderID', o.id,
                   'OrderDate', o.datePlaced,
                   'ShippingDate', o.dateShipped,
                   'OrderTotal',
                     (
                       SELECT ROUND(COALESCE(SUM(p2.currentPrice * ol2.quantity), 0), 2)
                       FROM Orderline ol2
                       JOIN Product p2 ON p2.id = ol2.product_id
                       WHERE ol2.order_id = o.id
                     ),
                   'items',
                     COALESCE(
                       (
                         SELECT JSON_ARRAYAGG(
                                  JSON_OBJECT(
                                    'ProductID', p3.id,
                                    'Quantity', ol3.quantity,
                                    'ProductName', p3.name
                                  )
                                )
                         FROM Orderline ol3
                         JOIN Product p3 ON p3.id = ol3.product_id
                         WHERE ol3.order_id = o.id
                       ),
                       JSON_ARRAY()
                     )
                 )
               )
        FROM `Order` o
        WHERE o.customer_id = c.id
      ),
      JSON_ARRAY()
    )
)
FROM Customer c
JOIN City ci ON ci.zip = c.zip
ORDER BY c.id
INTO OUTFILE '/var/lib/mysql-files/cust.json'
FIELDS TERMINATED BY ''
ESCAPED BY ''
LINES TERMINATED BY '\n';

-- ============================================================
-- CASE 3: Inventory Demand Signal
-- custom1.json
-- ============================================================
SELECT JSON_OBJECT(
  'ProductID', p.id,
  'productName', p.name,
  'currentPrice', p.currentPrice,
  'availableQuantity', p.availableQuantity,
  'total_units_sold',
    COALESCE(
      (SELECT SUM(ol.quantity) FROM Orderline ol WHERE ol.product_id = p.id),
      0
    ),
  'unique_customer_count',
    COALESCE(
      (
        SELECT COUNT(DISTINCT o.customer_id)
        FROM Orderline ol
        JOIN `Order` o ON o.id = ol.order_id
        WHERE ol.product_id = p.id
      ),
      0
    ),
  'recent_orders',
    COALESCE(
      (
        SELECT JSON_ARRAYAGG(
                 JSON_OBJECT(
                   'OrderID', y.order_id,
                   'OrderDate', y.datePlaced,
                   'Customer',
                     JSON_OBJECT(
                       'CustomerID', y.customer_id,
                       'CustomerName', y.customer_name,
                       'State', y.state
                     ),
                   'Quantity', y.quantity
                 )
               )
        FROM (
          SELECT
            o.id AS order_id,
            o.datePlaced,
            c.id AS customer_id,
            CONCAT(c.firstName, ' ', c.lastName) AS customer_name,
            ci.state,
            ol.quantity
          FROM Orderline ol
          JOIN `Order` o ON o.id = ol.order_id
          JOIN Customer c ON c.id = o.customer_id
          JOIN City ci ON ci.zip = c.zip
          WHERE ol.product_id = p.id
          ORDER BY o.datePlaced DESC, o.id DESC
        ) AS y
      ),
      JSON_ARRAY()
    )
)
FROM Product p
ORDER BY p.id
INTO OUTFILE '/var/lib/mysql-files/custom1.json'
FIELDS TERMINATED BY ''
ESCAPED BY ''
LINES TERMINATED BY '\n';

-- ============================================================
-- CASE 4: Regional Delivery Manifest
-- custom2.json
-- ============================================================
SELECT JSON_OBJECT(
  'State', s.state,
  'customers',
    COALESCE(
      (
        SELECT JSON_ARRAYAGG(
                 JSON_OBJECT(
                   'CustomerID', z.customer_id,
                   'CustomerName', z.customer_name,
                   'printed_address_1', z.printed_address_1,
                   'printed_address_2', z.printed_address_2,
                   'orders',
                     COALESCE(
                       (
                         SELECT JSON_ARRAYAGG(
                                  JSON_OBJECT(
                                    'OrderID', o.id,
                                    'OrderDate', o.datePlaced,
                                    'ShippingDate', o.dateShipped,
                                    'items',
                                      COALESCE(
                                        (
                                          SELECT JSON_ARRAYAGG(
                                                   JSON_OBJECT(
                                                     'ProductID', p.id,
                                                     'ProductName', p.name,
                                                     'Quantity', ol.quantity
                                                   )
                                                 )
                                          FROM Orderline ol
                                          JOIN Product p ON p.id = ol.product_id
                                          WHERE ol.order_id = o.id
                                        ),
                                        JSON_ARRAY()
                                      )
                                  )
                                )
                         FROM `Order` o
                         WHERE o.customer_id = z.customer_id
                       ),
                       JSON_ARRAY()
                     )
                 )
               )
        FROM (
          SELECT
            c.id AS customer_id,
            CONCAT(c.firstName, ' ', c.lastName) AS customer_name,
            CASE
              WHEN c.address2 IS NULL OR c.address2 = '' THEN c.address1
              ELSE CONCAT(c.address1, ' #', c.address2)
            END AS printed_address_1,
            CONCAT(ci.city, ', ', ci.state, '   ', LPAD(ci.zip, 5, '0')) AS printed_address_2
          FROM Customer c
          JOIN City ci ON ci.zip = c.zip
          WHERE ci.state = s.state
        ) AS z
      ),
      JSON_ARRAY()
    )
)
FROM (
  SELECT DISTINCT state
  FROM City
  WHERE state IS NOT NULL AND state <> ''
) AS s
ORDER BY s.state
INTO OUTFILE '/var/lib/mysql-files/custom2.json'
FIELDS TERMINATED BY ''
ESCAPED BY ''
LINES TERMINATED BY '\n';
EOF

chown "${LINUX_USER}:${LINUX_USER}" "${HOME_DIR}/etl.sql" "${HOME_DIR}/views.sql" "${HOME_DIR}/json.sql"

# ========================
# REMOVE OLD JSON FILES
# ========================
rm -f /var/lib/mysql-files/prod.json \
      /var/lib/mysql-files/cust.json \
      /var/lib/mysql-files/custom1.json \
      /var/lib/mysql-files/custom2.json

# ========================
# EXECUTE SQL SCRIPTS
# ========================
echo "### Building database from views.sql ###"
cd "${HOME_DIR}"
mariadb --local-infile=1 < "${HOME_DIR}/views.sql"

echo "### Generating JSON files from json.sql ###"
mariadb < "${HOME_DIR}/json.sql"

echo "### Listing generated files ###"
ls -l /var/lib/mysql-files/

echo "### JSON Milestone setup completed successfully ###"
echo "### Review /var/log/user-data.log if you need troubleshooting ###"

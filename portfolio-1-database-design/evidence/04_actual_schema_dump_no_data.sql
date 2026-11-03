
/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;
DROP TABLE IF EXISTS `accounts`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `accounts` (
  `account_id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `customer_id` int(10) unsigned NOT NULL,
  `account_number` char(10) NOT NULL,
  `account_type` enum('SAVINGS','CURRENT') NOT NULL,
  `currency` char(3) NOT NULL DEFAULT 'NGN',
  `balance` decimal(15,2) NOT NULL DEFAULT 0.00,
  `status` enum('ACTIVE','FROZEN','CLOSED') NOT NULL DEFAULT 'ACTIVE',
  `opened_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`account_id`),
  UNIQUE KEY `uq_accounts_number` (`account_number`),
  KEY `idx_accounts_customer` (`customer_id`),
  CONSTRAINT `fk_accounts_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`customer_id`) ON UPDATE CASCADE,
  CONSTRAINT `ck_accounts_balance_nonneg` CHECK (`balance` >= 0),
  CONSTRAINT `ck_accounts_number_format` CHECK (`account_number` regexp '^[0-9]{10}$')
) ENGINE=InnoDB AUTO_INCREMENT=12 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = cp850 */ ;
/*!50003 SET character_set_results = cp850 */ ;
/*!50003 SET collation_connection  = cp850_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER trg_accounts_after_insert
AFTER INSERT ON accounts
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (account_id, action, old_balance, new_balance, changed_by)
    VALUES (NEW.account_id, 'ACCOUNT_OPENED', NULL, NEW.balance, CURRENT_USER());
END */;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET @saved_cs_results     = @@character_set_results */ ;
/*!50003 SET @saved_col_connection = @@collation_connection */ ;
/*!50003 SET character_set_client  = cp850 */ ;
/*!50003 SET character_set_results = cp850 */ ;
/*!50003 SET collation_connection  = cp850_general_ci */ ;
/*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
/*!50003 SET sql_mode              = 'NO_ZERO_IN_DATE,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION' */ ;
DELIMITER ;;
/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER trg_accounts_after_update
AFTER UPDATE ON accounts
FOR EACH ROW
BEGIN
    
    IF NOT (OLD.balance <=> NEW.balance) THEN
        INSERT INTO audit_log (account_id, action, old_balance, new_balance, changed_by)
        VALUES (NEW.account_id, 'BALANCE_CHANGED', OLD.balance, NEW.balance, CURRENT_USER());
    END IF;
END */;;
DELIMITER ;
/*!50003 SET sql_mode              = @saved_sql_mode */ ;
/*!50003 SET character_set_client  = @saved_cs_client */ ;
/*!50003 SET character_set_results = @saved_cs_results */ ;
/*!50003 SET collation_connection  = @saved_col_connection */ ;
DROP TABLE IF EXISTS `audit_log`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `audit_log` (
  `audit_id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `account_id` int(10) unsigned NOT NULL,
  `action` enum('ACCOUNT_OPENED','BALANCE_CHANGED') NOT NULL,
  `old_balance` decimal(15,2) DEFAULT NULL,
  `new_balance` decimal(15,2) NOT NULL,
  `changed_by` varchar(100) NOT NULL,
  `changed_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`audit_id`),
  KEY `idx_audit_log_account_changed` (`account_id`,`changed_at`),
  CONSTRAINT `fk_audit_log_account` FOREIGN KEY (`account_id`) REFERENCES `accounts` (`account_id`) ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=29 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `beneficiaries`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `beneficiaries` (
  `beneficiary_id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `customer_id` int(10) unsigned NOT NULL,
  `beneficiary_account_id` int(10) unsigned NOT NULL,
  `nickname` varchar(50) NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`beneficiary_id`),
  UNIQUE KEY `uq_beneficiaries_customer_account` (`customer_id`,`beneficiary_account_id`),
  KEY `idx_beneficiaries_account` (`beneficiary_account_id`),
  CONSTRAINT `fk_beneficiaries_account` FOREIGN KEY (`beneficiary_account_id`) REFERENCES `accounts` (`account_id`) ON UPDATE CASCADE,
  CONSTRAINT `fk_beneficiaries_customer` FOREIGN KEY (`customer_id`) REFERENCES `customers` (`customer_id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB AUTO_INCREMENT=8 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `customers`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `customers` (
  `customer_id` int(10) unsigned NOT NULL AUTO_INCREMENT,
  `first_name` varchar(50) NOT NULL,
  `last_name` varchar(50) NOT NULL,
  `email` varchar(100) NOT NULL,
  `phone` varchar(20) NOT NULL,
  `status` enum('ACTIVE','SUSPENDED','CLOSED') NOT NULL DEFAULT 'ACTIVE',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`customer_id`),
  UNIQUE KEY `uq_customers_email` (`email`),
  UNIQUE KEY `uq_customers_phone` (`phone`)
) ENGINE=InnoDB AUTO_INCREMENT=11 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `transactions`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `transactions` (
  `transaction_id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `account_id` int(10) unsigned NOT NULL,
  `transfer_id` bigint(20) unsigned DEFAULT NULL,
  `transaction_type` enum('DEPOSIT','WITHDRAWAL','TRANSFER_DEBIT','TRANSFER_CREDIT') NOT NULL,
  `amount` decimal(15,2) NOT NULL,
  `balance_after` decimal(15,2) NOT NULL,
  `description` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`transaction_id`),
  KEY `idx_transactions_account_created` (`account_id`,`created_at`),
  KEY `idx_transactions_transfer` (`transfer_id`),
  CONSTRAINT `fk_transactions_account` FOREIGN KEY (`account_id`) REFERENCES `accounts` (`account_id`) ON UPDATE CASCADE,
  CONSTRAINT `fk_transactions_transfer` FOREIGN KEY (`transfer_id`) REFERENCES `transfers` (`transfer_id`) ON UPDATE CASCADE,
  CONSTRAINT `ck_transactions_amount_positive` CHECK (`amount` > 0),
  CONSTRAINT `ck_transactions_balance_nonneg` CHECK (`balance_after` >= 0),
  CONSTRAINT `ck_transactions_transfer_link` CHECK (`transaction_type` in ('TRANSFER_DEBIT','TRANSFER_CREDIT') = (`transfer_id` is not null))
) ENGINE=InnoDB AUTO_INCREMENT=21 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
DROP TABLE IF EXISTS `transfers`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `transfers` (
  `transfer_id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `reference` varchar(30) NOT NULL,
  `source_account_id` int(10) unsigned NOT NULL,
  `destination_account_id` int(10) unsigned NOT NULL,
  `amount` decimal(15,2) NOT NULL,
  `status` enum('PENDING','COMPLETED','FAILED','REVERSED') NOT NULL DEFAULT 'PENDING',
  `failure_reason` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `completed_at` datetime DEFAULT NULL,
  PRIMARY KEY (`transfer_id`),
  UNIQUE KEY `uq_transfers_reference` (`reference`),
  KEY `idx_transfers_source_created` (`source_account_id`,`created_at`),
  KEY `idx_transfers_destination` (`destination_account_id`),
  KEY `idx_transfers_status_created` (`status`,`created_at`),
  CONSTRAINT `fk_transfers_destination` FOREIGN KEY (`destination_account_id`) REFERENCES `accounts` (`account_id`) ON UPDATE CASCADE,
  CONSTRAINT `fk_transfers_source` FOREIGN KEY (`source_account_id`) REFERENCES `accounts` (`account_id`) ON UPDATE CASCADE,
  CONSTRAINT `ck_transfers_amount_positive` CHECK (`amount` > 0),
  CONSTRAINT `ck_transfers_different_accounts` CHECK (`source_account_id` <> `destination_account_id`),
  CONSTRAINT `ck_transfers_failure_reason` CHECK (`status` <> 'FAILED' or `failure_reason` is not null)
) ENGINE=InnoDB AUTO_INCREMENT=7 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;


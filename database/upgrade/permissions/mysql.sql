-- WolfAdmin: level permissions for the commands this fork adds.
--
-- Why this script exists
-- ----------------------
-- A stock WolfAdmin database (database/new/mysql.sql) never grants some of
-- the permissions the commands in luascripts/ are guarded by. Those commands
-- then answer "<command>: permission denied" for every player on the server,
-- including Server Owner, because no level - at any level id - has the
-- permission the command asks for.
--
-- WolfAdmin logs every one of them at startup, for example:
--
--   [WolfAdmin] 19 permission(s) are not granted to any level, so the
--   commands below are denied for every player:
--   [WolfAdmin]   'cheats' is needed by: give
--
-- Run this script once against the WolfAdmin database (the database named by
-- the db_database setting):
--
--   mysql -u <user> -p <database> < database/upgrade/permissions/mysql.sql
--
-- Every statement is idempotent, running the script twice changes nothing.
-- Remove a line instead of deleting rows if you want a level to lose a
-- permission again.
--
-- Note on 'lockplayers': the stock schema grants 'lockplayers' (plural), while
-- the code checks 'lockplayer' (singular, see auth.PERM_LOCKPLAYER). The
-- plural row never matches anything, so !plock and !punlock are denied until
-- the singular permission below is granted.

-- level 3 (Admin): banning and locking, on top of what the stock schema gives
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (3, 'banguid');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (3, 'banip');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (3, 'lockplayer');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (3, 'resetxp_self');

-- level 4 (Senior Admin): the fun and server-wide commands
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'banguid');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'banip');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'lockplayer');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'resetxp_self');

INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'resetxp');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'subnetban');

INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'ammopack');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'medpack');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'revive');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'disguise');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'poison');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'nade');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'lol');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'giball');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'throwall');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'crazysettings');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'warsettings');

-- multiview: ET: Legacy only, and only while g_multiview is enabled
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'multiview');

-- level 5 (Server Owner): everything above, plus the cheat commands
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'banguid');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'banip');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'lockplayer');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'resetxp_self');

INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'resetxp');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'subnetban');

INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'ammopack');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'medpack');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'revive');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'disguise');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'poison');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'nade');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'lol');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'giball');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'throwall');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'crazysettings');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'warsettings');

INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'multiview');
INSERT IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'cheats');

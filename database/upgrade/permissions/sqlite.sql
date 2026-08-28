-- WolfAdmin: level permissions for the commands this fork adds.
--
-- Why this script exists
-- ----------------------
-- A stock WolfAdmin database (database/new/sqlite.sql) never grants some of
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
-- Run this script once against the WolfAdmin database (the file named by the
-- db_file setting, "wolfadmin.db" by default):
--
--   sqlite3 wolfadmin.db < database/upgrade/permissions/sqlite.sql
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
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (3, 'banguid');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (3, 'banip');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (3, 'lockplayer');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (3, 'resetxp_self');

-- level 4 (Senior Admin): the fun and server-wide commands
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'banguid');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'banip');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'lockplayer');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'resetxp_self');

INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'resetxp');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'subnetban');

INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'ammopack');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'medpack');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'revive');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'disguise');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'poison');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'nade');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'lol');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'giball');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'throwall');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'crazysettings');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'warsettings');

-- multiview: ET: Legacy only, and only while g_multiview is enabled
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (4, 'multiview');

-- level 5 (Server Owner): everything above, plus the cheat commands
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'banguid');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'banip');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'lockplayer');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'resetxp_self');

INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'resetxp');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'subnetban');

INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'ammopack');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'medpack');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'revive');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'disguise');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'poison');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'nade');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'lol');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'giball');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'throwall');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'crazysettings');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'warsettings');

INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'multiview');
INSERT OR IGNORE INTO `level_permission`(`level_id`, `permission`) VALUES (5, 'cheats');

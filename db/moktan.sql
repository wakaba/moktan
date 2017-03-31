create table if not exists `object` (
  `id` bigint unsigned not null,
  `type` varbinary(127) not null,
  `timestamp` double not null,
  `data` mediumblob not null,
  primary key (`id`),
  key (`type`, `timestamp`),
  key (`timestamp`)
) default charset=binary engine=innodb;
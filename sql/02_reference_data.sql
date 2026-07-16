USE log_ingestor_v2;

INSERT INTO Cluster_Table (Server_ID, IP_Address, Log_Format, Location) VALUES
(1, '192.168.1.1', 'JSON', 'New York'),
(2, '192.168.1.2', 'XML', 'Mumbai'),
(3, '192.168.1.3', 'PlainText', 'Tokyo');

INSERT INTO Event_Type_Lookup (Event_Type_ID, Event_Name) VALUES
(1, 'PAGE_VIEW'),
(2, 'LOGIN_ATTEMPT'),
(3, 'LOGIN_SUCCESS'),
(4, 'LOGIN_FAILURE'),
(5, 'API_CALL'),
(6, 'ADMIN_ACCESS'),
(7, 'FILE_DOWNLOAD'),
(8, 'FIREWALL_BLOCK');

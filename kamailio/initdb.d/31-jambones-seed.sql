-- jambonz seed: the minimum to accept an inbound INVITE for "voicebot" from
-- Kamailio and route it to the OpenAI-Realtime voicebot application.
--
-- Inbound lookup (sbc-inbound): match the source IP (Kamailio internal leg,
-- 172.30.20.10) against an inbound sip_gateway (netmask=32) on a carrier that has
-- service_provider_sid set, then match the dialed number "voicebot" in
-- phone_numbers -> application -> webhooks.url (the websocket app).

USE jambones;

SET FOREIGN_KEY_CHECKS=0;

-- service provider
INSERT INTO service_providers (service_provider_sid, name)
VALUES ('2708b1b3-2736-40ea-b502-c53d8396247f', 'rig sp');

-- account (webhook_secret is NOT NULL)
INSERT INTO accounts (account_sid, service_provider_sid, name, webhook_secret, is_active)
VALUES ('9351f46a-678c-43f5-b8a6-d4eb58d131af',
        '2708b1b3-2736-40ea-b502-c53d8396247f',
        'rig account', 'wh_secret_seed', 1);

-- websocket "call hook" for the application = our voicebot app + its route path
INSERT INTO webhooks (webhook_sid, url, method)
VALUES ('d31568d0-b193-4a05-8ff6-778369bc6efe', 'ws://voicebot:3000/voicebot', 'POST');

-- the voicebot application (call_hook_sid -> the websocket above)
INSERT INTO applications
  (application_sid, account_sid, name, call_hook_sid,
   speech_synthesis_vendor, speech_synthesis_language, speech_synthesis_voice,
   speech_recognizer_vendor, speech_recognizer_language)
VALUES ('7087fe50-8acb-4f3b-b820-97b573723aab',
        '9351f46a-678c-43f5-b8a6-d4eb58d131af',
        'voicebot', 'd31568d0-b193-4a05-8ff6-778369bc6efe',
        'google', 'en-US', 'en-US-Standard-C', 'google', 'en-US');

-- carrier representing Kamailio (must have service_provider_sid set for the IP lookup)
INSERT INTO voip_carriers
  (voip_carrier_sid, name, service_provider_sid, account_sid, is_active, trunk_type)
VALUES ('11111111-1111-1111-1111-111111111111', 'kamailio',
        '2708b1b3-2736-40ea-b502-c53d8396247f',
        '9351f46a-678c-43f5-b8a6-d4eb58d131af', 1, 'static_ip');

-- inbound gateway whitelisting Kamailio's internal-leg IP
INSERT INTO sip_gateways
  (sip_gateway_sid, voip_carrier_sid, ipv4, netmask, port, inbound, outbound, is_active, protocol)
VALUES ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111',
        '172.30.20.10', 32, 5060, 1, 0, 1, 'udp');

-- the dialed number "voicebot" -> the application
INSERT INTO phone_numbers
  (phone_number_sid, number, voip_carrier_sid, account_sid, application_sid)
VALUES ('33333333-3333-3333-3333-333333333333', 'voicebot',
        '11111111-1111-1111-1111-111111111111',
        '9351f46a-678c-43f5-b8a6-d4eb58d131af',
        '7087fe50-8acb-4f3b-b820-97b573723aab');

SET FOREIGN_KEY_CHECKS=1;

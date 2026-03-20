-- Copyright 2021 SmartThings
-- Licensed under the Apache License, Version 2.0 (the "License");

local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"
local write = require "writeAttribute"
local device_management = require "st.zigbee.device_management"
local messages = require "st.zigbee.messages"
local zcl_messages = require "st.zigbee.zcl"

-- ZCL Clusters
local Basic = zcl_clusters.Basic
local OnOff = zcl_clusters.OnOff
local AnalogInput = zcl_clusters.AnalogInput
local SimpleMetering = zcl_clusters.SimpleMetering
local PowerConfiguration = zcl_clusters.PowerConfiguration

-- Capabilities
local battery = capabilities.battery
local valve = capabilities.valve
local powerSource = capabilities.powerSource
local refresh = capabilities.refresh
local gasMeter = capabilities.gasMeter

-------------------------------------------------------------------------------------------
-- HANDLERS
-------------------------------------------------------------------------------------------

local function flow_report_handler(driver, device, value, zb_rx)
  local raw_flow = value.value
  print(string.format("<<<< [FLOW SUCCESS] Cluster: 0x%04X, Attr: 0x%04X, Value: %.2f >>>>", 
        zb_rx.address_header.cluster.value, zb_rx.body.zcl_body.attr_id.value, raw_flow))
  
  device:emit_event(gasMeter.gasMeter({value = raw_flow, unit = "L"}))
end

-- Proper way to build a manual Zigbee Read Attribute message
local function read_attribute_raw(device, cluster_id, attr_id)
  local read_body = zcl_messages.zcl_clusters.global_commands.ReadAttribute({ attr_id })
  local header = zcl_messages.zcl_header.ZCLHeader({
    cmd = zcl_messages.zcl_clusters.global_commands.ReadAttribute.ID
  })
  local message_body = zcl_messages.zcl_message_body.ZCLMessageBody({
    zcl_header = header,
    zcl_body = read_body
  })
  return messages.ZigbeeMessageTx({
    address_header = device_management.build_address_header(device, cluster_id),
    body = message_body
  })
end

local function refresh_handler(driver, device)
  print("<<<< [REFRESH] Probing all potential Metering Attributes >>>>")
  
  -- 1. Standard Polls
  device:send(OnOff.attributes.OnOff:read(device))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  device:send(Basic.attributes.PowerSource:read(device))

  -- 2. AnalogInput (0x000C) Probe
  device:send(AnalogInput.attributes.PresentValue:read(device)) -- 0x0055
  device:send(read_attribute_raw(device, 0x000C, 0x0051))       -- 0x0051
  
  -- 3. SimpleMetering (0x0702) Probe
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device)) -- 0x0000
  device:send(read_attribute_raw(device, 0x0702, 0x0100))                       -- 0x0100

  -- 4. Manufacturer Specific (0xFC11) - Sonoff Private
  device:send(read_attribute_raw(device, 0xFC11, 0x0001))
  device:send(read_attribute_raw(device, 0xFC11, 0x0006))
end

local function device_added(self, device)
  print("<<<< [DEVICE ADDED] Initializing device >>>>")
  device:refresh()
end

-------------------------------------------------------------------------------------------
-- PREFERENCES (Remaining code is the same as before)
-------------------------------------------------------------------------------------------
local function do_Preferences(self, device, event, args)
  -- ... (Your existing do_Preferences code)
end

local zigbee_valve_driver_template = {
  supported_capabilities = { valve, battery, powerSource, refresh, gasMeter },
  capability_handlers = {
    [refresh.ID] = { [refresh.commands.refresh.NAME] = refresh_handler }
  },
  zigbee_handlers = {
    attr = {
      [AnalogInput.ID] = {
        [AnalogInput.attributes.PresentValue.ID] = flow_report_handler,
        [0x0051] = flow_report_handler
      },
      [SimpleMetering.ID] = {
        [SimpleMetering.attributes.CurrentSummationDelivered.ID] = flow_report_handler,
        [0x0100] = flow_report_handler
      },
      [0xFC11] = {
         [0x0001] = flow_report_handler,
         [0x0006] = flow_report_handler
      }
    }
  },
  lifecycle_handlers = {
    added = device_added,
    infoChanged = do_Preferences,
    doConfigure = function(self, device)
      device:configure()
    end
  }
}

defaults.register_for_default_handlers(zigbee_valve_driver_template, zigbee_valve_driver_template.supported_capabilities)
local zigbee_valve = ZigbeeDriver("SonoffValveMeter", zigbee_valve_driver_template)
zigbee_valve:run()
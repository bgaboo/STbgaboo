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

local function refresh_handler(driver, device)
  print("<<<< [REFRESH] Probing all potential Metering Attributes >>>>")
  
  -- 1. Standard Polls
  device:send(OnOff.attributes.OnOff:read(device))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  device:send(Basic.attributes.PowerSource:read(device))

  -- 2. Probe Sequence using global_commands (Bulletproof method)
  -- AnalogInput (0x000C)
  device:send(AnalogInput.attributes.PresentValue:read(device)) -- 0x0055
  device:send(zcl_clusters.global_commands.ReadAttribute(device, 0x000C, {0x0051}))
  
  -- SimpleMetering (0x0702)
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device)) -- 0x0000
  device:send(zcl_clusters.global_commands.ReadAttribute(device, 0x0702, {0x0100}))

  -- Manufacturer Specific (0xFC11)
  device:send(zcl_clusters.global_commands.ReadAttribute(device, 0xFC11, {0x0001}))
  device:send(zcl_clusters.global_commands.ReadAttribute(device, 0xFC11, {0x0006}))
end

local function device_added(self, device)
  print("<<<< [DEVICE ADDED] Initializing device >>>>")
  device:refresh()
end

-------------------------------------------------------------------------------------------
-- PREFERENCES
-------------------------------------------------------------------------------------------
local function do_Preferences(self, device, event, args)
  print("<< do_Prefrences >>")
  for id, value in pairs(device.preferences) do
    local oldPreferenceValue = args.old_st_store.preferences[id]
    local newParameterValue = device.preferences[id]
    if oldPreferenceValue ~= newParameterValue then
        if id == "restoreState" then
          print("<<< Write restore state >>>")
          local value_send = tonumber(newParameterValue)
          local data_value = {value = value_send, ID = 0x30}
          local cluster_id = {value = 0x0006}
          local attr_id = 0x4003
          write.write_attribute_function(device, cluster_id, attr_id, data_value)

          if newParameterValue == "255" then data_value = {value = 0x02, ID = 0x30} end
          attr_id = 0x8002
          write.write_attribute_function(device, cluster_id, attr_id, data_value)
        end
    end
  end
end

-------------------------------------------------------------------------------------------
-- DRIVER TEMPLATE
-------------------------------------------------------------------------------------------

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
  },
  health_check = false,
}

defaults.register_for_default_handlers(zigbee_valve_driver_template, zigbee_valve_driver_template.supported_capabilities)
local zigbee_valve = ZigbeeDriver("SonoffValveMeter", zigbee_valve_driver_template)
zigbee_valve:run()
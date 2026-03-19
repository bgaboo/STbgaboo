-- Copyright 2021 SmartThings
-- Licensed under the Apache License, Version 2.0 (the "License");

local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"
local write = require "writeAttribute"

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

-- Process Flow/Meter reports
local function flow_report_handler(driver, device, value, zb_rx)
  local raw_flow = value.value
  print(string.format("<<<< [FLOW SUCCESS] Cluster: 0x%04X, Attr: 0x%04X, Value: %.2f >>>>", zb_rx.address_header.cluster.value, zb_rx.body.zcl_body.attr_id.value, raw_flow))
  
  -- SONOFF SWV-BSP typically reports in Liters (L)
  device:emit_event(gasMeter.gasMeter({value = raw_flow, unit = "L"}))
end

-- Force the device to report all potential metering attributes
local function refresh_handler(driver, device)
  print("<<<< [REFRESH] Probing all potential Metering Attributes >>>>")
  
  -- 1. Standard Polls (Using built-in cluster definitions)
  device:send(OnOff.attributes.OnOff:read(device))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  device:send(Basic.attributes.PowerSource:read(device))

  -- 2. AnalogInput (0x000C) Probe
  -- Read 0x0055 (Standard)
  device:send(AnalogInput.attributes.PresentValue:read(device)) 
  -- Read 0x0051 (Sonoff Flow) - Corrected Syntax
  device:send(zcl_clusters.AnalogInput.attributes.PresentValue:read(device):set_attr_id(0x0051))
  
  -- 3. SimpleMetering (0x0702) Probe
  -- Read 0x0000 (Current Summation)
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
  -- Read 0x0100 (Water Specific) - Corrected Syntax
  device:send(zcl_clusters.SimpleMetering.attributes.CurrentSummationDelivered:read(device):set_attr_id(0x0100))
end

local function device_added(self, device)
  print("<<<< [DEVICE ADDED] Initializing device >>>>")
  device:refresh()
end

-------------------------------------------------------------------------------------------
-- PREFERENCES
-------------------------------------------------------------------------------------------

local function do_Preferences(self, device, event, args)
  print("<< do_Preferences >>")
  for id, _ in pairs(device.preferences) do
    local oldPreferenceValue = args.old_st_store.preferences[id]
    local newParameterValue = device.preferences[id]
    
    if oldPreferenceValue ~= newParameterValue then
      print("<< Preference changed name:", id, "old value:", oldPreferenceValue, "new value:", newParameterValue)

      if id == "restoreState" then
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
  supported_capabilities = {
    valve,
    battery,
    powerSource,
    refresh,
    gasMeter
  },
  
  capability_handlers = {
    [refresh.ID] = {
      [refresh.commands.refresh.NAME] = refresh_handler
    }
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
      }
    }
  },

  cluster_configurations = {
    [powerSource.ID] = {
      {
        cluster = Basic.ID,
        attribute = Basic.attributes.PowerSource.ID,
        minimum_interval = 5,
        maximum_interval = 600,
        data_type = Basic.attributes.PowerSource.base_type,
        configurable = true
      }
    }
  },

  lifecycle_handlers = {
    added = device_added,
    infoChanged = do_Preferences,
    doConfigure = function(self, device)
      print("<<<< [CONFIGURE] Setting up Reporting >>>>")
      device:configure()
      -- Try to bind reporting for the most likely flow cluster
      device:add_configured_attribute(AnalogInput.attributes.PresentValue)
      device:add_monitored_attribute(AnalogInput.attributes.PresentValue)
    end
  },

  sub_drivers = {},
  health_check = false,
}

defaults.register_for_default_handlers(zigbee_valve_driver_template, zigbee_valve_driver_template.supported_capabilities)

local zigbee_valve = ZigbeeDriver("SonoffValveMeter", zigbee_valve_driver_template)
zigbee_valve:run()
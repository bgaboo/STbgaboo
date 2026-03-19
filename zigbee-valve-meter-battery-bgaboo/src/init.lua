-- Copyright 2021 SmartThings
-- Licensed under the Apache License, Version 2.0 (the "License");

local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"
local write = require "writeAttribute"

-- Shorten cluster/capability references
local Basic = zcl_clusters.Basic
local OnOff = zcl_clusters.OnOff
local AnalogInput = zcl_clusters.AnalogInput
local SimpleMetering = zcl_clusters.SimpleMetering

local battery = capabilities.battery
local valve = capabilities.valve
local powerSource = capabilities.powerSource
local refresh = capabilities.refresh
local gasMeter = capabilities.gasMeter

-------------------------------------------------------------------------------------------
-- HANDLERS
-------------------------------------------------------------------------------------------

-- Handler for Water Flow / Metering (Cluster 0x000C or 0x0702)
local function flow_report_handler(driver, device, value, zb_rx)
  local raw_flow = value.value
  print(string.format("<<<< [FLOW REPORT] Device: %s, Value: %.2f >>>>", device.label, raw_flow))
  
  -- SONOFF SWV-BSP typically reports in Liters (L)
  device:emit_event(gasMeter.gasMeter({value = raw_flow, unit = "L"}))
end

-- Custom Refresh Handler: Forces the hub to ask for the Metering data
local function refresh_handler(driver, device)
  print("<<<< [REFRESH] Manually polling Valve, Battery, and Flow clusters >>>>")
  
  -- Standard Polls
  device:send(zcl_clusters.OnOff.attributes.OnOff:read(device))
  device:send(zcl_clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
  
  -- Metering Polls (SONOFF specific clusters)
  device:send(AnalogInput.attributes.PresentValue:read(device))
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
end

local function device_added(self, device)
  print("<<<< [DEVICE ADDED] Initializing device >>>>")
  device:refresh()
end

-------------------------------------------------------------------------------------------
-- PREFERENCES & LIFECYCLE
-------------------------------------------------------------------------------------------

local function do_Preferences(self, device, event, args)
  print("<< do_Preferences >>")
  for id, value in pairs(device.preferences) do
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
  
  -- Map Capability commands to Lua functions
  capability_handlers = {
    [refresh.ID] = {
      [refresh.commands.refresh.NAME] = refresh_handler
    }
  },
  
  -- Map Zigbee Attribute reports to Lua functions
  zigbee_handlers = {
    attr = {
      [AnalogInput.ID] = {
        [AnalogInput.attributes.PresentValue.ID] = flow_report_handler
      },
      [SimpleMetering.ID] = {
        [SimpleMetering.attributes.CurrentSummationDelivered.ID] = flow_report_handler
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
    },
    -- Automatic reporting for flow metering (SONOFF specific cluster)
    [gasMeter.ID] = {
      {
        cluster = AnalogInput.ID,
        attribute = AnalogInput.attributes.PresentValue.ID,
        minimum_interval = 1,
        maximum_interval = 300, -- 5 percenként akkor is küldjön adatot, ha nincs változás
        data_type = AnalogInput.attributes.PresentValue.base_type,
        reportable_change = 0.1, -- 0.1 liter változásnál már küldjön frissítést
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
      -- Manually ensure reporting is bound for the AnalogInput cluster
      device:add_configured_attribute(AnalogInput.attributes.PresentValue)
      device:add_monitored_attribute(AnalogInput.attributes.PresentValue)
    end
  },

  sub_drivers = {
    -- Placeholder for future sub-drivers (e.g., Tuya specific)
  },
  health_check = false,
}

-- Register defaults for Valve and Battery to save code space
defaults.register_for_default_handlers(zigbee_valve_driver_template, zigbee_valve_driver_template.supported_capabilities)

local zigbee_valve = ZigbeeDriver("zigbee-valve-meter-battery-bgaboo", zigbee_valve_driver_template)
zigbee_valve:run()
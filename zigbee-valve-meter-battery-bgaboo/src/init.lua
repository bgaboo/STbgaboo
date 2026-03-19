-- Copyright 2021 SmartThings

local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"

--ZCL
local zcl_clusters = require "st.zigbee.zcl.clusters"
local Basic = zcl_clusters.Basic
local AnalogInput = zcl_clusters.AnalogInput -- Új klaszter az átfolyáshoz

--Capability
local capabilities = require "st.capabilities"
local battery = capabilities.battery
local valve = capabilities.valve
local powerSource = capabilities.powerSource
local refresh = capabilities.refresh
local gasMeter = capabilities.gasMeter -- A vízátfolyás mérésére használt képesség

local write = require "writeAttribute"

-- Átfolyási adatok feldolgozása (Cluster 0x000C, Attr 0x0055)
local function flow_report_handler(driver, device, value, zb_rx)
  -- Az SWV-BSP literben küldi az értéket (Single Precision Floating Point)
  local flow_volume = value.value 
  -- Esemény küldése az alkalmazás felé
  device:emit_event(gasMeter.gasMeter({value = flow_volume, unit = "L"}))
  print(string.format("<<<< Vízátfolyás jelentés: %.2f L >>>>", flow_volume))
end

local function device_added(self, device)
  device:refresh()
end

--- Update preferences after infoChanged recived---
local function do_Preferences(self, device, event, args)
  print("<< do_Prefrences >>")
  -- (A preferenciák kezelése változatlan marad...)
  for id, value in pairs(device.preferences) do
    local oldPreferenceValue = args.old_st_store.preferences[id]
    local newParameterValue = device.preferences[id]
    
    if oldPreferenceValue ~= newParameterValue then
      print("<< Preference changed name:",id, "old value:",oldPreferenceValue, "new value:", newParameterValue)
      
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

-- Lazy load kezelő
local version = require "version"
local function lazy_load_if_possible(sub_driver_name)
    if version.api >= 9 then
      return ZigbeeDriver.lazy_load_sub_driver(require(sub_driver_name))
    else
      return require(sub_driver_name)
    end
end

local zigbee_valve_driver_template = {
  supported_capabilities = {
    valve,
    battery,
    powerSource,
    refresh,
    gasMeter -- Hozzáadva a támogatott képességekhez
  },
  -- Zigbee üzenetkezelők
  zigbee_handlers = {
    attr = {
      [AnalogInput.ID] = {
        [AnalogInput.attributes.PresentValue.ID] = flow_report_handler
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
    -- Automatikus jelentés (Reporting) konfigurálása az átfolyáshoz
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
      -- Kényszerített konfiguráció végrehajtása
      device:configure()
    end
  },
  sub_drivers = {
     lazy_load_if_possible("default_response")
  },
  health_check = false,
}

defaults.register_for_default_handlers(zigbee_valve_driver_template, zigbee_valve_driver_template.supported_capabilities)
local zigbee_valve = ZigbeeDriver("zigbee-valve-meter-battery-bgaboo", zigbee_valve_driver_template)
zigbee_valve:run()
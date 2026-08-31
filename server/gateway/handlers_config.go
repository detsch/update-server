// Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
// SPDX-License-Identifier: BSD-3-Clause-Clear

package gateway

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/labstack/echo/v4"
	toml "github.com/pelletier/go-toml"

	storage "github.com/foundriesio/update-server/storage/gateway"
)

type ConfigFileCreate struct {
	Name        string   `json:"name"`
	OnChanged   []string `json:"on-changed"`
	Value       string   `json:"value"`
	Unencrypted *bool    `json:"unencrypted"`
}
type ConfigCreate struct {
	Reason string             `json:"reason"`
	Files  []ConfigFileCreate `json:"files"`
}

// @Summary Update device's current configuration
// @Produce plain
// @Accept  json
// @Param   config body ConfigCreate true "Config create"
// @Success 201 ""
// @Router  /config [patch]
func (h handlers) configPatch(c echo.Context) error {
	req := c.Request()
	ctx := req.Context()
	d := CtxGetDevice(ctx)

	var newC ConfigCreate
	if err := ReadJsonBody(c, &newC); err != nil {
		return err
	}

	if len(newC.Files) == 0 {
		return EchoError(c, nil, http.StatusBadRequest, "no config files provided")
	}

	if !storage.ValidConfigsReasonRegex.MatchString(newC.Reason) {
		err := fmt.Errorf("reason must match pattern: %s", storage.ValidConfigsReasonRegex.String())
		return EchoError(c, err, http.StatusBadRequest, err.Error())
	}

	files, err := d.GetDeviceConfig()
	if err != nil {
		return EchoError(c, err, http.StatusInternalServerError, "failed to fetch device config")
	}

	validNames := []string{"wireguard-client", "fio-remote-actions"}

	for _, newFile := range newC.Files {
		if !slices.Contains(validNames, newFile.Name) {
			return EchoError(c, nil, http.StatusBadRequest, "invalid config file name")
		}
		unencrypted := false
		if newFile.Unencrypted != nil {
			unencrypted = *newFile.Unencrypted
		}
		files[newFile.Name] = ConfigFile{
			OnChanged:   newFile.OnChanged,
			Value:       newFile.Value,
			Unencrypted: unencrypted,
		}
	}

	data, err := json.Marshal(files)
	if err != nil {
		return EchoError(c, err, http.StatusInternalServerError, "failed to marshal config JSON")
	}
	if err := d.SaveDeviceConfig(newC.Reason, string(data)); err != nil {
		return EchoError(c, err, http.StatusInternalServerError, "failed to save device config")
	}

	return c.String(http.StatusCreated, "")
}

type ConfigFile = storage.ConfigFile

// @Summary Get device's current configuration
// @Produce json
// @Success 200 {object} map[string]ConfigFile
// @Router  /config [get]
func (h handlers) configGet(c echo.Context) error {
	req := c.Request()
	ctx := req.Context()
	log := CtxGetLog(ctx)
	d := CtxGetDevice(ctx)
	configs, timestamp, err := d.GetConfigs()
	if err != nil {
		return EchoError(c, err, http.StatusInternalServerError, "failed to fetch config")
	} else if timestamp == 0 {
		return c.NoContent(http.StatusNoContent)
	}

	// All times below use one second precision to account for devices which don't support subsecond timestamps.
	// A client is expected to use the Date header value in its subsequent If-Modified-Since header values.
	cts := time.Unix(timestamp, 0).UTC()
	ifModifiedSince := req.Header.Get("If-Modified-Since")
	if len(ifModifiedSince) > 0 {
		if dts, err := time.Parse(time.RFC1123, ifModifiedSince); err != nil {
			log.Warn("Unable to parse If-Modified-Since", "error", err, "if-modified-since", ifModifiedSince)
		} else if !cts.After(dts) { // Latest update made at or before if-modified-since
			return c.String(http.StatusNotModified, "")
		}
	}

	// A reference type here allows manipulating map values directly below.
	applied := storage.AppliedConfigs{
		Files: make(map[string]ConfigFile),
	}
	pacmanCfg := make(pacmanConfig)
	for idx, srcConfig := range configs {
		var cfg map[string]ConfigFile
		if srcConfig == nil {
			continue
		}
		// If srcConfig is not nil, audit fields must be set, even if the Files are empty.
		// That's a valid use case if the entire global, group, or device configs were deleted.
		auditTrail := &applied.AuditTrail[idx]
		auditTrail.Reason = srcConfig.Reason
		auditTrail.CreatedAt = srcConfig.CreatedAt
		auditTrail.CreatedBy = srcConfig.CreatedBy
		switch idx {
		case 1: // Group config
			auditTrail.Auxiliary = d.GroupName
		case 2: // Device config
			auditTrail.Auxiliary = d.Uuid
		}
		if len(srcConfig.RawFiles) == 0 {
			continue
		} else if err = json.Unmarshal([]byte(srcConfig.RawFiles), &cfg); err != nil {
			return EchoError(c, err, http.StatusInternalServerError, "failed to parse config JSON")
		}
		for k, v := range cfg {
			if k == storage.ConfigSotaOverride {
				if err = pacmanCfg.merge(v.Value); err != nil {
					return EchoError(c, err, http.StatusInternalServerError, "failed to parse sota toml config")
				}
			}
			applied.Files[k] = v
		}
	}
	if !pacmanCfg.empty() {
		// When pacmanCfg is non-empty, files are warranted to contain the sota override.
		sotaCfg := applied.Files[storage.ConfigSotaOverride]
		if sotaCfg.Value, err = pacmanCfg.encode(); err != nil {
			return EchoError(c, err, http.StatusInternalServerError, "failed to encode merged sota toml config")
		} else {
			// set back into a map, as sotaCfg is a value copy
			applied.Files[storage.ConfigSotaOverride] = sotaCfg
		}
	}
	c.Response().Header().Set("Date", cts.Format(time.RFC1123))
	applied.AppliedAt = time.Now().Unix()
	if err := d.SaveAppliedConfigs(applied); err != nil {
		log.Warn("Failed to save applied config", "device", d.Uuid, "error", err)
	}
	return c.JSON(http.StatusOK, applied.Files)
}

type pacmanConfig map[string]map[string]interface{}

func (p pacmanConfig) empty() bool {
	return len(p) == 0
}

func (p pacmanConfig) encode() (string, error) {
	buf := new(bytes.Buffer)
	encoder := toml.NewEncoder(buf).Indentation("")
	if err := encoder.Encode(p); err != nil {
		return "", err
	}
	// pelletier/go-toml always adds a leading newline - trim it
	return strings.TrimLeft(buf.String(), "\n"), nil
}

func (p pacmanConfig) merge(tomlString string) error {
	var data pacmanConfig
	buf := bytes.NewReader([]byte(tomlString))
	decoder := toml.NewDecoder(buf)
	err := decoder.Decode(&data)
	if err != nil {
		return err
	}
	for section, values := range data {
		if p[section] == nil {
			p[section] = values
			continue
		}
		for k, v := range values {
			p[section][k] = v
		}
	}
	return nil
}

// Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
// SPDX-License-Identifier: BSD-3-Clause-Clear

package updates

import (
	"fmt"

	"github.com/foundriesio/update-server/cli/api"
	"github.com/spf13/cobra"
)

var deleteCmd = &cobra.Command{
	Use:   "delete <update-name> [<update-name> ...]",
	Short: "Delete one or more updates",
	Long:  `Delete one or more updates from the server. Fails if devices are still assigned to an update.`,
	Args:  cobra.MinimumNArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		api := api.CtxGetApi(cmd.Context())
		for _, updateName := range args {
			if len(args) > 1 {
				fmt.Println("Deleting update:", updateName)
			}
			cobra.CheckErr(api.Updates().Delete(updateName))
		}
	},
}

func init() {
	UpdatesCmd.AddCommand(deleteCmd)
}

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// ANSI color codes
const (
	colorReset  = "\033[0m"
	colorBold   = "\033[1m"
	colorDim    = "\033[2m"
	colorRed    = "\033[31m"
	colorGreen  = "\033[32m"
	colorYellow = "\033[33m"
	colorBlue   = "\033[34m"
	colorCyan   = "\033[36m"
)

var spinnerDone chan struct{}

// showSpinner displays an animated spinner with a message.
func showSpinner(message string) {
	spinnerDone = make(chan struct{})
	go func() {
		frames := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
		i := 0
		for {
			select {
			case <-spinnerDone:
				fmt.Printf("\r  %s✓%s %s%s\n", colorGreen, colorReset, message, "                    ")
				return
			default:
				fmt.Printf("\r  %s%s%s %s%s%s ", colorCyan, frames[i%len(frames)], colorReset, colorDim, message, colorReset)
				i++
				time.Sleep(80 * time.Millisecond)
			}
		}
	}()
}

// clearSpinner stops the spinner.
func clearSpinner() {
	if spinnerDone != nil {
		close(spinnerDone)
		time.Sleep(100 * time.Millisecond) // Let the goroutine print the final message
	}
}

// displayYAMLPreview shows the generated YAML with a nice border and syntax highlighting.
func displayYAMLPreview(yamlContent, userPrompt string) {
	fmt.Println()
	fmt.Printf("  %s🤖 Prompt:%s %s\n", colorBold, colorReset, userPrompt)
	fmt.Println()

	// Simple YAML syntax highlighting
	lines := strings.Split(yamlContent, "\n")
	maxWidth := 0
	for _, line := range lines {
		if len(line) > maxWidth {
			maxWidth = len(line)
		}
	}
	if maxWidth < 50 {
		maxWidth = 50
	}

	// Top border
	fmt.Printf("  %s┌%s┐%s\n", colorCyan, strings.Repeat("─", maxWidth+2), colorReset)

	for _, line := range lines {
		if line == "" {
			continue
		}
		colored := highlightYAMLLine(line)
		// Pad to box width
		padding := maxWidth - len(line)
		if padding < 0 {
			padding = 0
		}
		fmt.Printf("  %s│%s %s%s %s│%s\n", colorCyan, colorReset, colored, strings.Repeat(" ", padding), colorCyan, colorReset)
	}

	// Bottom border
	fmt.Printf("  %s└%s┘%s\n", colorCyan, strings.Repeat("─", maxWidth+2), colorReset)
	fmt.Println()
}

// highlightYAMLLine applies simple syntax highlighting to a YAML line.
func highlightYAMLLine(line string) string {
	trimmed := strings.TrimSpace(line)
	indent := line[:len(line)-len(trimmed)]

	// Comments
	if strings.HasPrefix(trimmed, "#") {
		return indent + colorDim + trimmed + colorReset
	}
	// List items
	if strings.HasPrefix(trimmed, "- ") {
		return indent + colorYellow + "- " + colorReset + highlightYAMLLine(indent+trimmed[2:])
	}
	// Key: value pairs
	if idx := strings.Index(trimmed, ":"); idx >= 0 {
		key := trimmed[:idx]
		rest := trimmed[idx:]
		// apiVersion, kind = special
		if key == "apiVersion" || key == "kind" {
			return indent + colorCyan + colorBold + key + colorReset + colorDim + rest + colorReset
		}
		// Keys under metadata/spec
		return indent + colorBlue + key + colorReset + rest
	}
	return line
}

// handleUserAction prompts the user for what to do with the generated YAML.
func handleUserAction(yamlContent string) {
	fmt.Printf("  %sApply to cluster?%s [y/N/edit/save] > ", colorBold, colorReset)
	var action string
	fmt.Scanln(&action)
	fmt.Println()

	switch strings.ToLower(strings.TrimSpace(action)) {
	case "y", "yes":
		applyToCluster(yamlContent)
	case "edit", "e":
		editAndApply(yamlContent)
	case "save", "s":
		saveToFile(yamlContent)
	default:
		fmt.Printf("  %s→ YAML not applied. Copy it from above or run with --apply.%s\n\n", colorDim, colorReset)
	}
}

// applyToCluster pipes the YAML to kubectl apply.
func applyToCluster(yamlContent string) {
	cmd := exec.Command("kubectl", "apply", "-f", "-")
	cmd.Stdin = strings.NewReader(yamlContent)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		fmt.Printf("  %s✗ kubectl apply failed: %v%s\n\n", colorRed, err, colorReset)
		os.Exit(1)
	}

	fmt.Printf("  %s✓ Applied! Watch deployment: kubectl get aapi -w%s\n\n", colorGreen, colorReset)
}

// editAndApply opens the YAML in $EDITOR, then applies.
func editAndApply(yamlContent string) {
	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = "vi"
	}

	// Write to temp file
	tmpFile, err := os.CreateTemp("", "apictl-*.yaml")
	if err != nil {
		fmt.Printf("  %s✗ Failed to create temp file: %v%s\n\n", colorRed, err, colorReset)
		return
	}
	defer os.Remove(tmpFile.Name())
	tmpFile.WriteString(yamlContent)
	tmpFile.Close()

	// Open editor
	cmd := exec.Command(editor, tmpFile.Name())
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Printf("  %s✗ Editor failed: %v%s\n\n", colorRed, err, colorReset)
		return
	}

	// Read back
	edited, err := os.ReadFile(tmpFile.Name())
	if err != nil {
		fmt.Printf("  %s✗ Failed to read edited file: %v%s\n\n", colorRed, err, colorReset)
		return
	}

	fmt.Printf("  Apply edited YAML? [y/N] > ")
	var confirm string
	fmt.Scanln(&confirm)
	if strings.ToLower(confirm) == "y" {
		applyToCluster(string(edited))
	}
}

// saveToFile saves the YAML to a user-specified file.
func saveToFile(yamlContent string) {
	fmt.Printf("  Filename [api.yaml]: ")
	var filename string
	fmt.Scanln(&filename)
	if filename == "" {
		filename = "api.yaml"
	}

	if err := os.WriteFile(filename, []byte(yamlContent), 0644); err != nil {
		fmt.Printf("  %s✗ Failed to save: %v%s\n\n", colorRed, err, colorReset)
		return
	}
	fmt.Printf("  %s✓ Saved to %s%s\n\n", colorGreen, filename, colorReset)
}

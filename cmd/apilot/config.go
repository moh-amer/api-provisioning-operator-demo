package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config holds all user configuration for apilot.
type Config struct {
	OpenAI   OpenAIConfig   `yaml:"openai"`
	Defaults DefaultsConfig `yaml:"defaults"`
}

// OpenAIConfig holds OpenAI-specific settings.
type OpenAIConfig struct {
	APIKey string `yaml:"apiKey,omitempty"`
	Model  string `yaml:"model"`
}

// DefaultsConfig holds default values for generated YAMLs.
type DefaultsConfig struct {
	Organization string `yaml:"organization"`
	Environment  string `yaml:"environment"`
	Namespace    string `yaml:"namespace"`
}

// defaultConfig returns a Config with sensible defaults.
func defaultConfig() Config {
	return Config{
		OpenAI: OpenAIConfig{
			Model: "gpt-4o-mini",
		},
		Defaults: DefaultsConfig{
			Environment: "eval",
			Namespace:   "default",
		},
	}
}

// configPath returns the path to the config file.
func configPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "apilot", "config.yaml")
}

// loadConfig loads config from file, env vars, and flags (in priority order).
func loadConfig(flags map[string]string) Config {
	cfg := defaultConfig()

	// 1. Load from config file (lowest priority)
	if data, err := os.ReadFile(configPath()); err == nil {
		_ = yaml.Unmarshal(data, &cfg)
	}

	// 2. Override with environment variables
	if v := os.Getenv("OPENAI_API_KEY"); v != "" {
		cfg.OpenAI.APIKey = v
	}
	if v := os.Getenv("APIGEE_ORG"); v != "" {
		cfg.Defaults.Organization = v
	}
	if v := os.Getenv("APIGEE_ENV"); v != "" {
		cfg.Defaults.Environment = v
	}

	// 3. Override with flags (highest priority)
	if flags != nil {
		if v, ok := flags["api-key"]; ok {
			cfg.OpenAI.APIKey = v
		}
		if v, ok := flags["model"]; ok {
			cfg.OpenAI.Model = v
		}
		if v, ok := flags["org"]; ok {
			cfg.Defaults.Organization = v
		}
		if v, ok := flags["o"]; ok {
			cfg.Defaults.Organization = v
		}
		if v, ok := flags["env"]; ok {
			cfg.Defaults.Environment = v
		}
		if v, ok := flags["e"]; ok {
			cfg.Defaults.Environment = v
		}
		if v, ok := flags["namespace"]; ok {
			cfg.Defaults.Namespace = v
		}
		if v, ok := flags["n"]; ok {
			cfg.Defaults.Namespace = v
		}
	}

	return cfg
}

// resolveAPIKey resolves the OpenAI API key from all sources.
// Priority: flag > env var > K8s secret > config file
func resolveAPIKey(cfg Config) string {
	// Already resolved from flag or env var
	if cfg.OpenAI.APIKey != "" {
		return cfg.OpenAI.APIKey
	}

	// Try Kubernetes secret
	key := readAPIKeyFromK8sSecret()
	if key != "" {
		return key
	}

	return ""
}

// readAPIKeyFromK8sSecret reads the OpenAI API key from a Kubernetes secret.
// Secret name: openai-api-key
// Namespace: apigee-api-operator-system
// Key: api-key
func readAPIKeyFromK8sSecret() string {
	ctx := context.Background()
	_ = ctx
	cmd := exec.Command("kubectl", "get", "secret", "openai-api-key",
		"-n", "apigee-api-operator-system",
		"-o", "jsonpath={.data.api-key}")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}

	// base64 decode
	decoded, err := exec.Command("bash", "-c", fmt.Sprintf("echo '%s' | base64 -d", strings.TrimSpace(string(out)))).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(decoded))
}

// saveConfig saves the config to disk.
func saveConfig(cfg Config) error {
	path := configPath()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

// runConfigure runs the interactive configuration wizard.
func runConfigure() {
	cfg := loadConfig(nil)

	fmt.Println()
	fmt.Println("  \033[1m⚙️  apilot configuration\033[0m")
	fmt.Println()

	// API key
	fmt.Printf("  OpenAI API key")
	if cfg.OpenAI.APIKey != "" {
		masked := cfg.OpenAI.APIKey[:7] + "..." + cfg.OpenAI.APIKey[len(cfg.OpenAI.APIKey)-4:]
		fmt.Printf(" [%s]", masked)
	}
	fmt.Printf(": ")
	var apiKey string
	fmt.Scanln(&apiKey)
	if apiKey != "" {
		cfg.OpenAI.APIKey = apiKey
	}

	// Organization
	fmt.Printf("  GCP Project (Apigee org)")
	if cfg.Defaults.Organization != "" {
		fmt.Printf(" [%s]", cfg.Defaults.Organization)
	}
	fmt.Printf(": ")
	var org string
	fmt.Scanln(&org)
	if org != "" {
		cfg.Defaults.Organization = org
	}

	// Environment
	fmt.Printf("  Apigee environment [%s]: ", cfg.Defaults.Environment)
	var env string
	fmt.Scanln(&env)
	if env != "" {
		cfg.Defaults.Environment = env
	}

	// Model
	fmt.Printf("  OpenAI model [%s]: ", cfg.OpenAI.Model)
	var model string
	fmt.Scanln(&model)
	if model != "" {
		cfg.OpenAI.Model = model
	}

	// Save
	if err := saveConfig(cfg); err != nil {
		fmt.Printf("\n  \033[31m✗ Failed to save config: %v\033[0m\n\n", err)
		os.Exit(1)
	}

	fmt.Printf("\n  \033[32m✓ Config saved to %s\033[0m\n", configPath())

	// Also offer to create K8s secret
	if cfg.OpenAI.APIKey != "" {
		fmt.Println()
		fmt.Printf("  Store API key as Kubernetes secret? [y/N]: ")
		var storeK8s string
		fmt.Scanln(&storeK8s)
		if strings.ToLower(storeK8s) == "y" {
			createK8sSecret(cfg.OpenAI.APIKey)
		}
	}

	fmt.Println()
}

// createK8sSecret creates the OpenAI API key as a Kubernetes secret.
func createK8sSecret(apiKey string) {
	cmd := exec.Command("kubectl", "create", "secret", "generic", "openai-api-key",
		"--namespace", "apigee-api-operator-system",
		"--from-literal=api-key="+apiKey,
		"--dry-run=client", "-o", "yaml")
	yamlOut, err := cmd.Output()
	if err != nil {
		fmt.Printf("  \033[31m✗ Failed to generate secret YAML: %v\033[0m\n", err)
		return
	}

	// Apply it
	applyCmd := exec.Command("kubectl", "apply", "-f", "-")
	applyCmd.Stdin = strings.NewReader(string(yamlOut))
	applyCmd.Stdout = os.Stdout
	applyCmd.Stderr = os.Stderr
	if err := applyCmd.Run(); err != nil {
		fmt.Printf("  \033[31m✗ Failed to create secret: %v\033[0m\n", err)
		return
	}
	fmt.Printf("  \033[32m✓ Secret 'openai-api-key' created in namespace 'apigee-api-operator-system'\033[0m\n")
}

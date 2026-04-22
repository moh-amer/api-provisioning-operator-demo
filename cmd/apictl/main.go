// Package main implements apictl — a CLI tool that converts natural language
// descriptions into valid ApigeeAPI Kubernetes YAML manifests using OpenAI.
//
// Usage:
//
//	apictl generate "weather API at wttr.in, rate limit 100/min"
//	apictl generate "payments API with API key auth" --apply
//	apictl configure
//	apictl examples
package main

import (
	"fmt"
	"os"
	"strings"
)

const version = "0.1.0"

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "generate", "gen", "g":
		runGenerate(os.Args[2:])
	case "configure", "config":
		runConfigure()
	case "examples", "ex":
		runExamples()
	case "version", "--version", "-v":
		fmt.Printf("apictl %s\n", version)
	case "help", "--help", "-h":
		printUsage()
	default:
		// If no subcommand, treat the entire args as a prompt for generate
		runGenerate(os.Args[1:])
	}
}

func printUsage() {
	fmt.Println()
	fmt.Println("  \033[1mapictl\033[0m — AI-powered ApigeeAPI YAML generator")
	fmt.Println()
	fmt.Println("  \033[36mUSAGE\033[0m")
	fmt.Printf("    apictl generate \"description...\"   Convert English → ApigeeAPI YAML\n")
	fmt.Printf("    apictl configure                   Set OpenAI API key & defaults\n")
	fmt.Printf("    apictl examples                    Show example prompts\n")
	fmt.Printf("    apictl version                     Print version\n")
	fmt.Println()
	fmt.Println("  \033[36mFLAGS (generate)\033[0m")
	fmt.Printf("    --org, -o       Apigee organization (GCP project)\n")
	fmt.Printf("    --env, -e       Apigee environment (default: eval)\n")
	fmt.Printf("    --namespace, -n Kubernetes namespace (default: default)\n")
	fmt.Printf("    --apply, -y     Output YAML to stdout without confirmation\n")
	fmt.Printf("    --model         OpenAI model (default: gpt-4o-mini)\n")
	fmt.Println()
	fmt.Println("  \033[36mAPI KEY\033[0m")
	fmt.Printf("    The OpenAI API key is loaded from (in priority order):\n")
	fmt.Printf("    1. --api-key flag\n")
	fmt.Printf("    2. OPENAI_API_KEY environment variable\n")
	fmt.Printf("    3. Kubernetes secret 'openai-api-key' in namespace 'apigee-api-operator-system'\n")
	fmt.Printf("    4. Config file ~/.config/apictl/config.yaml\n")
	fmt.Println()
	fmt.Println("  \033[36mEXAMPLES\033[0m")
	fmt.Printf("    apictl generate \"weather API at wttr.in with rate limiting\"\n")
	fmt.Printf("    apictl generate \"payments API with API key auth\" --apply | kubectl apply -f -\n")
	fmt.Printf("    apictl \"notification service, 5000 requests per day\"\n")
	fmt.Println()
}

func runExamples() {
	fmt.Println()
	fmt.Println("  \033[1m🤖 Example Prompts for apictl generate\033[0m")
	fmt.Println()

	examples := []struct {
		prompt string
		desc   string
	}{
		{
			prompt: "weather API using wttr.in",
			desc:   "Simple proxy, no policies",
		},
		{
			prompt: "weather API at wttr.in with rate limiting at 100 requests per minute",
			desc:   "SpikeArrest + Quota policies",
		},
		{
			prompt: "payments API with API key authentication and strict rate limiting",
			desc:   "VerifyAPIKey + SpikeArrest + Quota",
		},
		{
			prompt: "notification service that allows 5000 requests per day",
			desc:   "Quota-only policy",
		},
		{
			prompt: "public search API with CORS support for https://myapp.com",
			desc:   "CORS policy with specific origin",
		},
		{
			prompt: "secure internal orders API with OAuth2 and 10 requests per second spike protection",
			desc:   "OAuthV2 + SpikeArrest",
		},
	}

	for i, ex := range examples {
		fmt.Printf("  \033[33m%d.\033[0m \033[1m%s\033[0m\n", i+1, ex.prompt)
		fmt.Printf("     \033[2m→ %s\033[0m\n\n", ex.desc)
	}

	fmt.Println("  \033[36mUsage:\033[0m")
	fmt.Printf("    apictl generate \"%s\"\n", examples[0].prompt)
	fmt.Println()

	// Also print the one-liner shortcut
	fmt.Println("  \033[36mShortcut (skip 'generate'):\033[0m")
	fmt.Printf("    apictl \"%s\"\n", examples[1].prompt)
	fmt.Println()
}

// parseFlags parses flags from args, returning the remaining positional args
// and a map of flag values. Supports --key=value and --key value forms.
func parseFlags(args []string) (positional []string, flags map[string]string) {
	flags = make(map[string]string)
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if strings.HasPrefix(arg, "--") || strings.HasPrefix(arg, "-") {
			key := strings.TrimLeft(arg, "-")
			// Handle --key=value
			if idx := strings.Index(key, "="); idx >= 0 {
				flags[key[:idx]] = key[idx+1:]
				continue
			}
			// Handle boolean flags
			if key == "apply" || key == "y" {
				flags["apply"] = "true"
				continue
			}
			// Handle --key value
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				flags[key] = args[i+1]
				i++
			}
		} else {
			positional = append(positional, arg)
		}
	}
	return
}

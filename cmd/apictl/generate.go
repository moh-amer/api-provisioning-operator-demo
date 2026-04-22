package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/invopop/jsonschema"
	"github.com/openai/openai-go/v3"
)

// APISpec is the structured output schema returned by the LLM.
// It maps directly to ApigeeAPISpec fields (excluding org/env/namespace
// which are injected by the CLI from config).
type APISpec struct {
	Name        string       `json:"name" jsonschema_description:"API name in lowercase kebab-case, e.g. weather-api"`
	BasePath    string       `json:"basePath" jsonschema_description:"URL path prefix starting with /, e.g. /weather"`
	TargetURL   string       `json:"targetUrl" jsonschema_description:"Backend URL starting with https://, e.g. https://wttr.in"`
	Description string       `json:"description" jsonschema_description:"Human-readable description of the API"`
	Policies    []PolicySpec `json:"policies" jsonschema_description:"Ordered list of Apigee policies"`
}

// PolicySpec uses explicit fields instead of map[string]string because
// OpenAI's strict structured output requires additionalProperties:false
// at every level, which is incompatible with Go maps.
// The model fills in relevant fields and leaves others as empty strings.
type PolicySpec struct {
	Type           string `json:"type" jsonschema:"enum=Quota,enum=SpikeArrest,enum=VerifyAPIKey,enum=CORS,enum=OAuthV2" jsonschema_description:"Apigee policy type"`
	Rate           string `json:"rate" jsonschema_description:"SpikeArrest rate. Format: Nps or Npm. Example: 100pm, 10ps. Empty if not SpikeArrest."`
	Allow          string `json:"allow" jsonschema_description:"Quota max requests per interval. Example: 1000. Empty if not Quota."`
	Interval       string `json:"interval" jsonschema_description:"Quota interval count. Example: 1. Empty if not Quota."`
	TimeUnit       string `json:"timeUnit" jsonschema_description:"Quota time unit: minute, hour, day, month. Empty if not Quota."`
	ApiKeyLocation string `json:"apiKeyLocation" jsonschema_description:"VerifyAPIKey location: queryparam or header. Empty if not VerifyAPIKey."`
	ApiKeyName     string `json:"apiKeyName" jsonschema_description:"VerifyAPIKey param/header name. Example: x-api-key. Empty if not VerifyAPIKey."`
	AllowOrigins   string `json:"allowOrigins" jsonschema_description:"CORS allowed origin. Example: * or https://myapp.com. Empty if not CORS."`
	AllowMethods   string `json:"allowMethods" jsonschema_description:"CORS allowed methods. Example: GET,POST,DELETE. Empty if not CORS."`
	AllowHeaders   string `json:"allowHeaders" jsonschema_description:"CORS allowed headers. Example: Content-Type,Authorization. Empty if not CORS."`
}

// toConfigMap converts the flat PolicySpec fields into a key-value config map,
// including only non-empty fields relevant to the policy type.
func (p PolicySpec) toConfigMap() map[string]string {
	cfg := make(map[string]string)
	switch p.Type {
	case "SpikeArrest":
		if p.Rate != "" {
			cfg["rate"] = p.Rate
		}
	case "Quota":
		if p.Allow != "" {
			cfg["allow"] = p.Allow
		}
		if p.Interval != "" {
			cfg["interval"] = p.Interval
		}
		if p.TimeUnit != "" {
			cfg["timeUnit"] = p.TimeUnit
		}
	case "VerifyAPIKey":
		if p.ApiKeyLocation != "" {
			cfg["apiKeyLocation"] = p.ApiKeyLocation
		}
		if p.ApiKeyName != "" {
			cfg["apiKeyName"] = p.ApiKeyName
		}
	case "CORS":
		if p.AllowOrigins != "" {
			cfg["allowOrigins"] = p.AllowOrigins
		}
		if p.AllowMethods != "" {
			cfg["allowMethods"] = p.AllowMethods
		}
		if p.AllowHeaders != "" {
			cfg["allowHeaders"] = p.AllowHeaders
		}
	// OAuthV2 has no config
	}
	return cfg
}

// generateSchema creates the JSON schema for structured output.
func generateSchema[T any]() interface{} {
	reflector := jsonschema.Reflector{
		AllowAdditionalProperties: false,
		DoNotReference:            true,
	}
	var v T
	return reflector.Reflect(v)
}

var apiSpecSchema = generateSchema[APISpec]()

// runGenerate is the main generate command handler.
func runGenerate(args []string) {
	positional, flags := parseFlags(args)
	cfg := loadConfig(flags)

	// Resolve API key
	apiKey := resolveAPIKey(cfg)
	if apiKey == "" {
		fmt.Println()
		fmt.Println("  \033[31m✗ No OpenAI API key found.\033[0m")
		fmt.Println()
		fmt.Println("  Set it via one of:")
		fmt.Println("    1. export OPENAI_API_KEY=sk-...")
		fmt.Println("    2. kubectl create secret generic openai-api-key \\")
		fmt.Println("         -n apigee-api-operator-system --from-literal=api-key=sk-...")
		fmt.Println("    3. apictl configure")
		fmt.Println()
		os.Exit(1)
	}

	// Get the prompt
	prompt := strings.Join(positional, " ")
	if prompt == "" {
		// Try reading from stdin
		stat, _ := os.Stdin.Stat()
		if (stat.Mode() & os.ModeCharDevice) == 0 {
			data := make([]byte, 4096)
			n, _ := os.Stdin.Read(data)
			prompt = strings.TrimSpace(string(data[:n]))
		}
	}
	if prompt == "" {
		fmt.Println()
		fmt.Println("  \033[31m✗ No description provided.\033[0m")
		fmt.Println("  Usage: apictl generate \"weather API at wttr.in\"")
		fmt.Println()
		os.Exit(1)
	}

	// Check organization is set
	if cfg.Defaults.Organization == "" {
		fmt.Println()
		fmt.Println("  \033[31m✗ No Apigee organization (GCP project) configured.\033[0m")
		fmt.Println("  Set it via: apictl configure, --org flag, or APIGEE_ORG env var")
		fmt.Println()
		os.Exit(1)
	}

	autoApply := flags["apply"] == "true"

	// Call OpenAI
	spec, err := callOpenAI(context.Background(), apiKey, cfg.OpenAI.Model, prompt)
	if err != nil {
		fmt.Printf("\n  \033[31m✗ OpenAI error: %v\033[0m\n\n", err)
		os.Exit(1)
	}

	// Build the full YAML
	yamlContent := buildFullYAML(spec, cfg)

	if autoApply {
		// Raw YAML output for piping
		fmt.Print(yamlContent)
		return
	}

	// Interactive mode
	displayYAMLPreview(yamlContent, prompt)
	handleUserAction(yamlContent)
}

// callOpenAI calls the OpenAI API with structured output to generate an APISpec.
func callOpenAI(ctx context.Context, apiKey, model, prompt string) (*APISpec, error) {
	// Set API key in env for the SDK
	os.Setenv("OPENAI_API_KEY", apiKey)
	client := openai.NewClient()

	if model == "" {
		model = "gpt-4o-mini"
	}

	showSpinner("Generating ApigeeAPI from your description")

	schemaParam := openai.ResponseFormatJSONSchemaJSONSchemaParam{
		Name:        "apigee_api_spec",
		Description: openai.String("An Apigee API proxy specification for Kubernetes"),
		Schema:      apiSpecSchema,
		Strict:      openai.Bool(true),
	}

	chat, err := client.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
		Messages: []openai.ChatCompletionMessageParamUnion{
			openai.SystemMessage(buildSystemPrompt()),
			openai.UserMessage(prompt),
		},
		ResponseFormat: openai.ChatCompletionNewParamsResponseFormatUnion{
			OfJSONSchema: &openai.ResponseFormatJSONSchemaParam{JSONSchema: schemaParam},
		},
		Model: model,
	})
	if err != nil {
		clearSpinner()
		return nil, fmt.Errorf("API call failed: %w", err)
	}

	clearSpinner()

	if len(chat.Choices) == 0 {
		return nil, fmt.Errorf("no response from OpenAI")
	}

	var spec APISpec
	if err := json.Unmarshal([]byte(chat.Choices[0].Message.Content), &spec); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w\nRaw: %s", err, chat.Choices[0].Message.Content)
	}

	return &spec, nil
}

// buildFullYAML constructs the complete ApigeeAPI YAML from the AI-generated spec.
func buildFullYAML(spec *APISpec, cfg Config) string {
	var b strings.Builder

	b.WriteString("apiVersion: apigee.example.com/v1alpha1\n")
	b.WriteString("kind: ApigeeAPI\n")
	b.WriteString("metadata:\n")
	b.WriteString(fmt.Sprintf("  name: %s\n", spec.Name))
	b.WriteString(fmt.Sprintf("  namespace: %s\n", cfg.Defaults.Namespace))
	b.WriteString("spec:\n")
	b.WriteString(fmt.Sprintf("  organization: %q\n", cfg.Defaults.Organization))
	b.WriteString(fmt.Sprintf("  environment: %q\n", cfg.Defaults.Environment))
	b.WriteString(fmt.Sprintf("  basePath: %q\n", spec.BasePath))
	b.WriteString(fmt.Sprintf("  targetUrl: %q\n", spec.TargetURL))
	if spec.Description != "" {
		b.WriteString(fmt.Sprintf("  description: %q\n", spec.Description))
	}

	if len(spec.Policies) > 0 {
		b.WriteString("  policies:\n")
		for _, p := range spec.Policies {
			b.WriteString(fmt.Sprintf("    - type: %s\n", p.Type))
			cfg := p.toConfigMap()
			if len(cfg) > 0 {
				b.WriteString("      config:\n")
				for k, v := range cfg {
					b.WriteString(fmt.Sprintf("        %s: %q\n", k, v))
				}
			}
		}
	}

	return b.String()
}

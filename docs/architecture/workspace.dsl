// Regenerate the SVGs from this directory:
//   docker run --rm -v "$PWD:/work" -w /work structurizr/structurizr export -workspace workspace.dsl -format plantuml -output exports
//   docker run --rm -v "$PWD/exports:/data" -w /data plantuml/plantuml -tsvg "structurizr-*.puml"
workspace "Agentic developer platform" "A local Kubernetes platform that governs every model and tool call an agent makes." {

    !identifiers hierarchical

    model {
        agentTeam = person "Agent team" "Builds and deploys an agent. Holds no model credential."
        platformTeam = person "Platform team" "Owns the model catalogue, the allow-lists, the budgets, and the network policy."

        provider = softwareSystem "Hosted model provider" "OpenRouter. Serves the hosted model behind the smart alias." "External"
        aws = softwareSystem "AWS" "Secrets Manager and DynamoDB. floci emulates both inside the cluster." "External"

        adp = softwareSystem "Agentic developer platform" "Runs agents that hold no credentials. One gateway decides what each agent may call." {
            agent = container "research-agent" "Sample durable agent. Each model call and tool call is a recorded workflow activity." "Python, Dapr Workflow"
            gateway = container "AI gateway" "Verifies the caller, checks the allow-list and the token budget, guards prompts, routes, and attaches provider keys." "agentgateway"
            models = container "Local models" "Serve the fast alias, and the smart alias when the provider fails." "Ollama, llama3.2"
            keySync = container "Key sync" "Copies provider keys into the gateway's namespace only." "External Secrets"
            ordersTools = container "Orders tools" "lookup_order and initiate_return. Opt-in stage." "MCP server, Python"
            broker = container "Code broker" "run_python. Fetches the rows itself, so they never pass through the model. Opt-in stage." "MCP server, Python"
            sandbox = container "Sandbox" "Runs model-written code with its own kernel and no network." "gVisor, agent-sandbox"
            telemetry = container "Telemetry" "One trace per agent run, the gateway's access log, metrics, and alerts." "otel-lgtm, Alertmanager"
        }

        agentTeam -> adp.agent "Deploys, with a ServiceAccount"
        platformTeam -> adp.gateway "Sets models, allow-lists, and budgets" "Git, Kustomize"
        adp.agent -> adp.gateway "Calls models and tools with a ServiceAccount token" "OpenAI API, MCP"
        adp.gateway -> adp.models "Routes fast, and smart on fallback" "HTTP"
        adp.gateway -> provider "Routes smart and attaches the key" "HTTPS"
        adp.gateway -> adp.ordersTools "Calls tools under a policy per tool" "MCP"
        adp.gateway -> adp.broker "Calls run_python for one identity" "MCP"
        adp.broker -> adp.sandbox "Hands over rows and code as files"
        adp.keySync -> aws "Reads provider keys" "Secrets Manager"
        adp.keySync -> adp.gateway "Writes the key Secret"
        adp.agent -> aws "Stores workflow state" "Dapr state API, DynamoDB"
        adp.ordersTools -> aws "Reads orders" "DynamoDB"
        adp.gateway -> adp.telemetry "Sends traces and the access log" "OTLP"
        adp.agent -> adp.telemetry "Sends traces" "OTLP"
    }

    views {
        systemContext adp "Context" "Who uses the platform and what it depends on." {
            include *
            autolayout lr
        }
        container adp "Containers" "The parts of the platform and the calls between them." {
            include *
            exclude platformTeam
            autolayout lr
        }
        styles {
            element "Person" {
                shape person
                background #08427b
                color #ffffff
            }
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "External" {
                background #999999
                color #ffffff
            }
        }
    }
}

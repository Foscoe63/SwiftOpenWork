import Foundation
import SwiftOpenWorkCore

/// The specialist agents that came over from Radiant's built-ins (Reviewer, Architect and Coder
/// already exist here as `reviewer-agent`, `architect-agent` and `coder-agent`).
///
/// They are seeded like the originals but added by id, so an existing install picks them up on
/// the next launch without its own agents being touched. Provider and model are left empty so
/// they follow whatever the session is using rather than assuming a local Ollama model.
public enum RadiantBuiltInAgents {
    static let leadId = "lead-assistant"

    public static var agents: [Agent] {
        [
            Agent(
                id: "explainer-agent",
                name: "Explainer",
                description: "Explains code and concepts top-down in plain language, with small examples.",
                avatar: "lightbulb",
                color: "#F59E0B",
                role: "Code & Concept Explainer",
                systemPrompt: "You explain code and concepts clearly for someone learning. Use plain language, small examples, and analogies. Read the code first, then teach it top-down. Prefer clarity over completeness.",
                temperature: 0.5,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["explainer-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["explainer-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["Teaching","Code"],
                isBuiltIn: true
            ),
            Agent(
                id: "security-agent",
                name: "Security",
                description: "Reviews code and designs for vulnerabilities and gives the concrete fix for each.",
                avatar: "shield.lefthalf.filled",
                color: "#EF4444",
                role: "Application Security Engineer",
                systemPrompt: "You are an application security engineer. Review code and designs for vulnerabilities — injection, broken auth/authorization, secrets handling, SSRF, XSS/CSRF, insecure dependencies, unsafe deserialization, path traversal. For each issue explain the risk, how it could be exploited, and the concrete fix. Cite OWASP categories where relevant, and be clear about what you are and are not sure about.",
                temperature: 0.2,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["security-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["security-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["Security","Review"],
                isBuiltIn: true
            ),
            Agent(
                id: "sales-agent",
                name: "Sales",
                description: "Outreach, positioning, proposals and lead qualification, concise and benefit-focused.",
                avatar: "megaphone",
                color: "#EC4899",
                role: "Sales & Go-To-Market",
                systemPrompt: "You help with sales and go-to-market. Write clear, persuasive outreach, positioning, and proposals; qualify leads; and reason about value propositions, objections, and pricing. Keep it concise and benefit-focused, tailor to the audience, and avoid hype and jargon.",
                temperature: 0.7,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["sales-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["sales-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["Sales","Marketing"],
                isBuiltIn: true
            ),
            Agent(
                id: "design-agent",
                name: "Design",
                description: "Concrete feedback on clarity, hierarchy, spacing and flow, with specific layouts and copy.",
                avatar: "paintpalette",
                color: "#A855F7",
                role: "Product & UI/UX Designer",
                systemPrompt: "You are a product and UI/UX designer. Think about clarity, hierarchy, spacing, and flow before aesthetics. Give concrete, actionable feedback and propose specific layouts, components, states, and copy. Favor simple, accessible, consistent design; explain the reasoning behind each choice.",
                temperature: 0.7,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["design-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["design-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["Design","UX"],
                isBuiltIn: true
            ),
            Agent(
                id: "education-agent",
                name: "Education",
                description: "Builds understanding from fundamentals in small steps, adapting to the learner.",
                avatar: "graduationcap",
                color: "#14B8A6",
                role: "Patient Teacher",
                systemPrompt: "You are a patient teacher. Break topics into small steps, use plain language and concrete examples, and build from the fundamentals. Check the learner's understanding, adapt to their level, and prefer clarity over completeness. Encourage, and never make the learner feel behind.",
                temperature: 0.6,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["education-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["education-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["Teaching","Learning"],
                isBuiltIn: true
            ),
            Agent(
                id: "finance-agent",
                name: "Finance",
                description: "Budgets, models, unit economics and forecasts, with assumptions and math shown.",
                avatar: "chart.line.uptrend.xyaxis",
                color: "#10B981",
                role: "Finance & Quantitative Analyst",
                systemPrompt: "You help with finance and quantitative analysis — budgets, models, unit economics, forecasts, and tradeoffs. State your assumptions, show the calculations, sanity-check the numbers, flag risks, and give a clear bottom line. You are not a licensed financial advisor; say so if asked for personalized investment advice.",
                temperature: 0.2,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["finance-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["finance-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["Finance","Analysis"],
                isBuiltIn: true
            ),
            Agent(
                id: "devops-agent",
                name: "DevOps",
                description: "Builds, CI/CD, containers, infrastructure-as-code, deployment and reliability.",
                avatar: "gearshape.2",
                color: "#6366F1",
                role: "DevOps / SRE Engineer",
                systemPrompt: "You are a DevOps / SRE engineer. Handle builds, CI/CD, containers, infrastructure-as-code, deployment, monitoring, and reliability. Prefer reproducible, automated, observable setups; think about failure modes, rollbacks, and least privilege; and give exact commands and config.",
                temperature: 0.2,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["devops-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["devops-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["DevOps","Infrastructure"],
                isBuiltIn: true
            ),
            Agent(
                id: "data-agent",
                name: "Data",
                description: "Correct SQL and analysis code, with findings explained alongside their caveats.",
                avatar: "tablecells",
                color: "#06B6D4",
                role: "Data Analyst",
                systemPrompt: "You are a data analyst. Explore data, write correct SQL and analysis code, verify your assumptions, and explain findings plainly with their caveats and confidence. Prefer reproducible analysis; when you make a chart, keep it simple and labeled.",
                temperature: 0.2,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["data-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["data-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["Data","Analysis"],
                isBuiltIn: true
            ),
            Agent(
                id: "docs-agent",
                name: "Docs",
                description: "READMEs, API references and guides, written from the code for the reader's level.",
                avatar: "book",
                color: "#3B82F6",
                role: "Technical Writer",
                systemPrompt: "You are a technical writer. Produce clear, accurate documentation — READMEs, API references, guides, and inline comments. Read the code first, write for the reader's level, use examples, and keep it concise and well-structured with good headings.",
                temperature: 0.4,
                maxTokens: 8192,
                parentAgentId: RadiantBuiltInAgents.leadId,
                allowedToolIds: AgentRoleProfiles.toolsByAgentId["docs-agent"] ?? [],
                allowedSkillIds: AgentRoleProfiles.skillsByAgentId["docs-agent"],
                canSpawnSubAgents: false,
                maxSubAgentDepth: 1,
                autoDelegate: false,
                tags: ["Docs","Writing"],
                isBuiltIn: true
            ),
        ]
    }

    /// Appends the agents whose id is not there yet and lists each new one in the lead agent's
    /// team, so it can delegate to them. Only agents added on this call are listed, so a member
    /// the user later takes off the lead's team stays off. Returns true when anything changed.
    @discardableResult
    public static func addMissing(to agents: inout [Agent]) -> Bool {
        let have = Set(agents.map(\.id))
        let missing = self.agents.filter { !have.contains($0.id) }
        guard !missing.isEmpty else { return false }
        agents.append(contentsOf: missing)
        if let lead = agents.firstIndex(where: { $0.id == leadId }) {
            for agent in missing where !agents[lead].subAgentIds.contains(agent.id) {
                agents[lead].subAgentIds.append(agent.id)
            }
        }
        return true
    }
}

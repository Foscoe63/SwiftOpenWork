import Foundation
import Testing
@testable import SwiftOpenWorkCore

@Suite("External team import")
struct ExternalTeamImportTests {
    static let openMaus = """
    ---
    botmrr: 1
    id: 100x-marketing
    name: Launch a Measurable Campaign
    tagline: Find a sharp position.
    summary: A four-agent growth crew.
    requirements:
      apps:
        - slug: slack
          label: Slack
          reason: Share briefs.
          optional: true
    agents:
      - key: maya
        name: Maya
        title: Growth Lead
        description: Turn goals into bets.
        playbooks:
          - positioning-brief
      - key: lens
        name: Lens
        title: Growth Analyst
        description: Define measurement.
    chiefOfStaff: maya
    rooms:
      - key: campaign-room
        name: Campaign Room
        members:
          - maya
          - lens
        bulletin: Do not fabricate data.
    routines:
      - key: weekly
        name: Weekly review
        agent: lens
        prompt: Review experiments.
        schedule:
          type: daily
          time: 15:00
          weekdays:
            - 5
        enabledAfterInstall: false
    playbooks:
      - key: positioning-brief
        name: Positioning Brief
        instructions: Clarify the audience: who, why.
    ---

    # Launch
    """

    static let botteams = """
    ---
    slug: new-hire-ramp
    name: New-hire 30-60-90
    tagline: Turns a role into a plan.
    section: Workplace
    connectors:
      - Google Docs
    bot_roster:
      - name: Ramp planner
        persona: Writes a 30-60-90 from the role brief.
    rooms: []
    routines:
      - name: Ramp pass
        owner: Ramp planner
        schedule: Every weekday at 09:00
        prompt: Draft the plan. Do not send.
    suggest:
      - text: Never send mail.
        on: true
      - text: Ignore me.
        on: false
    ---

    Body.
    """

    @Test func openMausTeamBecomesMembersWithALead() throws {
        let t = try #require(ExternalTeamImport.convert(markdown: Self.openMaus))
        #expect(t.members.map(\.name) == ["Maya", "Lens"])
        #expect(t.members[0].isLead && !t.members[1].isLead)
        #expect(t.members[0].instructions.contains("Clarify the audience: who, why."))
        #expect(t.members[1].instructions.contains("Do not fabricate data."))
        #expect(t.connectors == ["Slack"])
        #expect(t.routineCount == 1)
    }

    @Test func botteamsBotKeepsPersonaAndOnlyTheRulesThatAreOn() throws {
        let t = try #require(ExternalTeamImport.convert(markdown: Self.botteams))
        #expect(t.members.count == 1)
        #expect(t.members[0].instructions.contains("Never send mail."))
        #expect(!t.members[0].instructions.contains("Ignore me."))
        #expect(t.connectors == ["Google Docs"])
    }

    @Test func otherFilesAreNotTeams() {
        #expect(ExternalTeamImport.convert(markdown: "# Just notes\n") == nil)
    }

    @Test func githubPageLinksResolveToRawFiles() throws {
        let page = try #require(URL(string: "https://github.com/ellelion/botteams/blob/main/bots/new-hire-ramp.md"))
        #expect(GitHubSource.rawURL(for: page).absoluteString == "https://raw.githubusercontent.com/ellelion/botteams/main/bots/new-hire-ramp.md")
        #expect(GitHubSource.isRepoLink(try #require(URL(string: "https://github.com/milind-soni/openmausbot-teams"))))
        #expect(!GitHubSource.isRepoLink(page))
    }
}

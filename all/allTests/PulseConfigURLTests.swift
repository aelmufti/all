//
//  PulseConfigURLTests.swift
//  allTests
//
//  Couvre `PulseConfig.normalizedBaseURL(fromUserInput:)` — la partie PURE de
//  la normalisation d'adresse Pulse (le fix du bug « bouton Se connecter
//  désactivé alors que je remplis tout » : une adresse sans schéma
//  `https://` n'était jamais retenue, donc `baseURL` restait `nil`).
//
//  Volontairement sur la fonction pure, PAS sur `setBaseURL(...)` : ce dernier
//  écrit le global `PulseConfig.baseURL`, dont `PulseSocleTests` documente la
//  course inter-suites (Swift Testing parallélise les suites). On ne mute donc
//  jamais ce global ici.
//

import Testing
import Foundation
@testable import all

@Suite struct PulseConfigURLTests {
    @Test func prependsHttpsWhenSchemeMissing() {
        let url = PulseConfig.normalizedBaseURL(fromUserInput: "pulse.tailnet.ts.net")
        #expect(url?.absoluteString == "https://pulse.tailnet.ts.net")
    }

    @Test func keepsExplicitScheme() {
        #expect(PulseConfig.normalizedBaseURL(fromUserInput: "http://192.168.1.10:3000")?
            .absoluteString == "http://192.168.1.10:3000")
        #expect(PulseConfig.normalizedBaseURL(fromUserInput: "https://pulse.ts.net")?
            .scheme == "https")
    }

    @Test func trimsWhitespace() {
        let url = PulseConfig.normalizedBaseURL(fromUserInput: "  pulse.ts.net  ")
        #expect(url?.absoluteString == "https://pulse.ts.net")
    }

    @Test func emptyOrBlankIsNil() {
        #expect(PulseConfig.normalizedBaseURL(fromUserInput: "") == nil)
        #expect(PulseConfig.normalizedBaseURL(fromUserInput: "   ") == nil)
    }

    @Test func rejectsInputWithoutHost() {
        // « https:// » seul : schéma présent mais pas d'hôte → inexploitable.
        #expect(PulseConfig.normalizedBaseURL(fromUserInput: "https://") == nil)
    }
}

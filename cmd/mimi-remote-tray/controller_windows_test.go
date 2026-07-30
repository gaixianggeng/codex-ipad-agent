//go:build windows

package main

import "testing"

func TestPairingTerminalReservationIsSingleInstance(t *testing.T) {
	controller := &agentController{}
	if !controller.reservePairingTerminal() {
		t.Fatal("first pairing terminal reservation should succeed")
	}
	if controller.reservePairingTerminal() {
		t.Fatal("second pairing terminal reservation should be rejected")
	}
	if !controller.pairingTerminalIsOpen() {
		t.Fatal("pairing terminal should be marked open")
	}

	controller.releasePairingTerminal()
	if controller.pairingTerminalIsOpen() {
		t.Fatal("pairing terminal should be marked closed after release")
	}
	if !controller.reservePairingTerminal() {
		t.Fatal("pairing terminal should be reservable after release")
	}
}

func TestMenuPairCommandIDIsStable(t *testing.T) {
	if menuStatus != 100 {
		t.Fatalf("menu status command ID = %d, want 100", menuStatus)
	}
	if menuPair != 105 {
		t.Fatalf("menu pair command ID = %d, want 105", menuPair)
	}
	if menuExitAndStop != 108 {
		t.Fatalf("menu exit-and-stop command ID = %d, want 108", menuExitAndStop)
	}
	if menuDoctorFix != 109 {
		t.Fatalf("menu doctor-fix command ID = %d, want 109", menuDoctorFix)
	}
}

func TestDoctorArgumentsOnlyRequestFixWhenSelected(t *testing.T) {
	plain := doctorArguments(false)
	if len(plain) != 1 || plain[0] != "doctor" {
		t.Fatalf("plain doctor arguments = %#v", plain)
	}
	fix := doctorArguments(true)
	if len(fix) != 2 || fix[0] != "doctor" || fix[1] != "--fix" {
		t.Fatalf("doctor fix arguments = %#v", fix)
	}
}

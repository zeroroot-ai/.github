package main

import (
	"fmt"
	"log"
)

func GetSecret() string { return "s3cr3t" }

func GetName() string { return "alice" }

// Positive: a value from a secret-shaped function reaches log.Printf.
func leak() {
	s := GetSecret()
	log.Printf("token: %s", s)
}

// Positive: the same, straight into fmt.Printf.
func leakFmt() {
	fmt.Printf("token: %s", GetSecret())
}

// Negative: a value that is not a secret reaches the same sink.
func fine() {
	n := GetName()
	log.Printf("user: %s", n)
}

// Negative: the secret is returned, never logged.
func used() string {
	return GetSecret()
}

func main() { leak(); leakFmt(); fine(); _ = used() }

package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
)

func getHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
}

func getHello(w http.ResponseWriter, r *http.Request) {
	var name string
	if r.URL.Query().Has("name") {
		name = r.URL.Query().Get("name")
	} else {
		name = "World"
	}
	fmt.Fprintf(w, "Hello %s\n", name)
}

func handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		_, _ = fmt.Fprintln(w, "Hello get")
	} else if r.Method == http.MethodPost {
		bodyData, err := io.ReadAll(r.Body)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_, _ = fmt.Fprintf(w, "Hello post %s\n", bodyData)
	} else {
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", getHealth)
	mux.HandleFunc("/hello", getHello)
	mux.HandleFunc("/", handleRoot)

	fmt.Println("Starting server")

	err := http.ListenAndServe(":8080", mux)
	if errors.Is(err, http.ErrServerClosed) {
		fmt.Println("Server closed")
	} else if err != nil {
		fmt.Printf("error starting server: %v\n", err)
		os.Exit(1)
	}
}

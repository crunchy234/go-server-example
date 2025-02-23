package main

import (
	"errors"
	"fmt"
	"net/http"
	"os"
)

func getHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(200)
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

//TIP <p>To run your code, right-click the code and select <b>Run</b>.</p> <p>Alternatively, click
// the <icon src="AllIcons.Actions.Execute"/> icon in the gutter and select the <b>Run</b> menu item from here.</p>

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", getHealth)
	mux.HandleFunc("/hello", getHello)

	err := http.ListenAndServe(":8080", mux)
	if errors.Is(err, http.ErrServerClosed) {
		fmt.Println("Server closed")
	} else if err != nil {
		fmt.Printf("error starting server: %v\n", err)
		os.Exit(1)
	}
}

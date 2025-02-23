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

//TIP <p>To run your code, right-click the code and select <b>Run</b>.</p> <p>Alternatively, click
// the <icon src="AllIcons.Actions.Execute"/> icon in the gutter and select the <b>Run</b> menu item from here.</p>

func main() {
	http.HandleFunc("/health", getHealth)
	err := http.ListenAndServe(":8080", nil)
	if errors.Is(err, http.ErrServerClosed) {
		fmt.Println("Server closed")
	} else if err != nil {
		fmt.Printf("error starting server: %v\n", err)
		os.Exit(1)
	}
}

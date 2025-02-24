package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	cfgFile string
)

// HTTP handlers (keeping your existing handlers)
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
	_, _ = fmt.Fprintf(w, "Hello %s\n", name)
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

func runServer(_ *cobra.Command, _ []string) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", getHealth)
	mux.HandleFunc("/hello", getHello)
	mux.HandleFunc("/", handleRoot)

	port := viper.GetString("port")
	addr := fmt.Sprintf(":%s", port)
	fmt.Printf("Starting server on port %s\n", port)

	err := http.ListenAndServe(addr, mux)
	if errors.Is(err, http.ErrServerClosed) {
		fmt.Println("Server closed")
		return nil
	} else if err != nil {
		return fmt.Errorf("error starting server: %w", err)
	}
	return nil
}

func initConfig() {
	if cfgFile != "" {
		// Use config file from the flag
		viper.SetConfigFile(cfgFile)
	} else {
		// Search config in current directory and home directory
		home, err := os.UserHomeDir()
		if err == nil {
			viper.AddConfigPath(home)
		}
		viper.AddConfigPath(".")
		viper.SetConfigType("yaml")
		viper.SetConfigName("config")
	}

	// Read environment variables
	viper.AutomaticEnv()
	viper.SetEnvPrefix("SERVER") // Will be uppercased automatically

	// Read in config file
	if err := viper.ReadInConfig(); err == nil {
		fmt.Println("Using config file:", viper.ConfigFileUsed())
	}
}

func main() {
	rootCmd := &cobra.Command{
		Use:   "server",
		Short: "A simple HTTP server",
		Long: `A simple HTTP server that handles various endpoints including:
- /health for health checks
- /hello for greeting (supports name parameter)
- / for root endpoint (supports GET and POST)`,
		RunE: runServer,
	}

	// Persistent flags (available to all commands)
	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "", "config file (default is ./config.yaml or $HOME/config.yaml)")

	// Local flags
	rootCmd.Flags().StringP("port", "p", "8080", "Port number for the server")

	// Bind Cobra flags with Viper
	err := viper.BindPFlag("port", rootCmd.Flags().Lookup("port"))
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	// Initialize Viper config
	cobra.OnInitialize(initConfig)

	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

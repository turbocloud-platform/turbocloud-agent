package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"slices"
	"time"

	"github.com/rqlite/gorqlite"
)

type Proxy struct {
	Id              string
	ContainerId     string
	ServerPrivateIP string
	Port            string
	Domain          string
	EnvironmentId   string
	DeploymentId    string
}

type CaddyRecord struct {
	ReverseProxy string
	Domain       string
}

func handleProxyPost(w http.ResponseWriter, r *http.Request) {
	var proxy Proxy
	err := decodeJSONBody(w, r, &proxy, true)

	if err != nil {
		var mr *malformedRequest
		if errors.As(err, &mr) {
			http.Error(w, mr.msg, mr.status)
		} else {
			log.Print(err.Error())
			http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		}
		return
	}

	addProxy(&proxy)

	jsonBytes, err := json.Marshal(proxy)
	if err != nil {
		fmt.Println("Cannot convert Proxy object into JSON:", err)
		return
	}

	fmt.Fprint(w, string(jsonBytes))

}

func handleProxyDelete(w http.ResponseWriter, r *http.Request) {
	proxyId := r.PathValue("id")

	if !deleteProxy(proxyId) {
		fmt.Println("Cannot delete Proxy from Proxy table")
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}

	fmt.Fprint(w, "")

}

func handleProxyGet(w http.ResponseWriter, r *http.Request) {

	jsonBytes, err := json.Marshal(getAllProxies())
	if err != nil {
		fmt.Println("Cannot convert Proxy object into JSON:", err)
		return
	}

	fmt.Fprint(w, string(jsonBytes))
}

func reloadProxyServer() {

	//We reload proxy server only on Balancer machines
	if !slices.Contains(thisMachine.Types, MachineTypeBalancer) {
		return
	}

	const caddyfilePath = `/etc/caddy/Caddyfile`

	f, err := os.Create(caddyfilePath)
	if err != nil {
		fmt.Println("Cannot open/create Caddyfile:", err)
	}

	caddyfileTemplate := createTemplate("caddyfile", `
# This file is updated automatically by turbocloud-agent.service
# Don't edit it manually - all your edits will be removed

{
	order coraza_waf first
    acme_ca https://acme.zerossl.com/v2/DV90
    email   agent@turbocloud.dev

}

{{.TURBOCLOUD_AGENT_DOMAIN}} {

    coraza_waf {
        load_owasp_crs
        directives `+"`"+`
            Include @coraza.conf-recommended
            Include @crs-setup.conf.example
            Include @owasp_crs/*.conf
            SecRuleEngine On
        `+"`"+`
        }


    reverse_proxy /hey localhost:{{.TURBOCLOUD_AGENT_PORT}}
    reverse_proxy /deploy/* localhost:{{.TURBOCLOUD_AGENT_PORT}}
    reverse_proxy /join/* localhost:{{.TURBOCLOUD_AGENT_PORT}}
    reverse_proxy * abort
}

192.168.202.1.dns.turbocloud.dev {

    coraza_waf {
        load_owasp_crs
        directives `+"`"+`
            Include @coraza.conf-recommended
            Include @crs-setup.conf.example
            Include @owasp_crs/*.conf
            SecRuleEngine On
		`+"`"+`
        }

    reverse_proxy * localhost:5445
}
`)

	var templateBytes bytes.Buffer
	templateData := map[string]string{
		"TURBOCLOUD_AGENT_DOMAIN": os.Getenv("TURBOCLOUD_AGENT_DOMAIN"),
		"TURBOCLOUD_AGENT_PORT":   PORT,
	}

	if err := caddyfileTemplate.Execute(&templateBytes, templateData); err != nil {
		fmt.Println("Cannot execute template for Caddyfile:", err)
	}

	var templateDomainBytes bytes.Buffer

	proxies := getAllProxies()
	if proxies == nil {
		return
	}

	//Create an array with CaddyRecord
	var caddyRecords = []CaddyRecord{}

	for _, proxy := range proxies {
		idx := slices.IndexFunc(caddyRecords, func(c CaddyRecord) bool { return c.Domain == proxy.Domain })

		if idx == -1 {
			var caddyRecord CaddyRecord
			caddyRecord.Domain = proxy.Domain
			caddyRecord.ReverseProxy = proxy.ServerPrivateIP + ":" + proxy.Port
			caddyRecords = append(caddyRecords, caddyRecord)
		} else {
			caddyRecords[idx].ReverseProxy += " " + proxy.ServerPrivateIP + ":" + proxy.Port
		}
	}

	caddyfileDomainTemplate := createTemplate("caddyfile", `
	{{ range . }}

{{.Domain}} {

    # coraza_waf {
        # load_owasp_crs
        # directives `+"`"+`
            # Include @coraza.conf-recommended
            # Include @crs-setup.conf.example
            # Include @owasp_crs/*.conf
            # SecRuleEngine On
		# `+"`"+`
        # }

    reverse_proxy * {{.ReverseProxy}}
}

{{ end }}

`)

	if err := caddyfileDomainTemplate.Execute(&templateDomainBytes, caddyRecords); err != nil {
		fmt.Println("Cannot execute template for Caddyfile:", err)
	}
	// A `WriteString` is also available.
	_, err = f.WriteString(templateBytes.String() + templateDomainBytes.String())

	if err != nil {
		fmt.Println("Cannot save Caddyfile:", err)
	}

	f.Sync()

	_, err = exec.Command("caddy", "reload", "-c", caddyfilePath).Output()
	if err != nil {
		switch e := err.(type) {
		case *exec.Error:
			fmt.Println("Failed executing 'caddy reload' :", err)
		case *exec.ExitError:
			fmt.Println("'caddy reload' exited with error code =", e.ExitCode())
		}
	}

}

func addProxy(proxy *Proxy) {

	id, err := NanoId(7)
	if err != nil {
		fmt.Println("Cannot generate new NanoId for Proxy:", err)
		return
	}

	proxy.Id = id

	_, err = connection.WriteParameterized(
		[]gorqlite.ParameterizedStatement{
			{
				Query:     "INSERT INTO Proxy( Id, ContainerId, ServerPrivateIP, Port, Domain, EnvironmentId, DeploymentId) VALUES(?, ?, ?, ?, ?, ?, ?)",
				Arguments: []interface{}{proxy.Id, proxy.ContainerId, proxy.ServerPrivateIP, proxy.Port, proxy.Domain, proxy.EnvironmentId, proxy.DeploymentId},
			},
		},
	)

	if err != nil {
		fmt.Printf(" Cannot write to Proxy table: %s\n", err.Error())
	}

}

func deleteProxy(proxyId string) (result bool) {
	_, err := connection.WriteParameterized(
		[]gorqlite.ParameterizedStatement{
			{
				Query:     "DELETE FROM Proxy WHERE Id = ?",
				Arguments: []interface{}{proxyId},
			},
		},
	)

	if err != nil {
		fmt.Printf(" Cannot delete a record from Proxy table: %s\n", err.Error())
		return false
	}

	return true
}

func deleteProxyByEnvironmentId(environmentId string) (result bool) {
	_, err := connection.WriteParameterized(
		[]gorqlite.ParameterizedStatement{
			{
				Query:     "DELETE FROM Proxy WHERE EnvironmentId = ?",
				Arguments: []interface{}{environmentId},
			},
		},
	)

	if err != nil {
		fmt.Printf(" Cannot delete a record from Proxy table by EnvironmentId: %s\n", err.Error())
		return false
	}

	return true
}

func getAllProxies() []Proxy {
	var proxies = []Proxy{}

	rows, err := connection.QueryOneParameterized(
		gorqlite.ParameterizedStatement{
			Query:     "SELECT Id, ContainerId, ServerPrivateIP, Port, Domain, EnvironmentId, DeploymentId from Proxy",
			Arguments: []interface{}{},
		},
	)

	if err != nil {
		fmt.Printf(" Cannot read from Proxy table: %s\n", err.Error())
		return nil
	}

	for rows.Next() {
		var Id string
		var ContainerId string
		var ServerPrivateIP string
		var Port string
		var Domain string
		var EnvironmentId string
		var DeploymentId string

		err := rows.Scan(&Id, &ContainerId, &ServerPrivateIP, &Port, &Domain, &EnvironmentId, &DeploymentId)
		if err != nil {
			fmt.Printf(" Cannot run Scan: %s\n", err.Error())
			return nil
		}
		loadProxy := Proxy{
			Id:              Id,
			ContainerId:     ContainerId,
			ServerPrivateIP: ServerPrivateIP,
			Port:            Port,
			Domain:          Domain,
			EnvironmentId:   EnvironmentId,
			DeploymentId:    DeploymentId,
		}
		proxies = append(proxies, loadProxy)
	}
	return proxies
}

func deleteProxiesIfDeploymentIdNotEqual(environmentId string, deploymentId string) (result bool) {

	_, err := connection.WriteParameterized(
		[]gorqlite.ParameterizedStatement{{
			Query:     "DELETE FROM Proxy WHERE EnvironmentId = ? AND DeploymentId != ?",
			Arguments: []interface{}{environmentId, deploymentId},
		},
		},
	)

	if err != nil {
		fmt.Printf(" Cannot read from the Proxy table: %s\n", err.Error())
		return false
	}

	return true
}
func startProxyCheckerWorker() {
	//We get proxy from DB with timestamp > timestamp_of_last_check
	//If there are some new proxies - call reloadProxy()
	for range time.Tick(time.Second * 2) {
		go func() {
			reloadProxyServer()
		}()
	}
}

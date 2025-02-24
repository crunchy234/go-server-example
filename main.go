package main

import (
	"fmt"
	"github.com/pulumi/pulumi-aws/sdk/v6/go/aws/ecs"
	"github.com/pulumi/pulumi-awsx/sdk/v2/go/awsx/ec2"
	"github.com/pulumi/pulumi-awsx/sdk/v2/go/awsx/ecr"
	ecrx "github.com/pulumi/pulumi-awsx/sdk/v2/go/awsx/ecr"
	ecsx "github.com/pulumi/pulumi-awsx/sdk/v2/go/awsx/ecs"
	lbx "github.com/pulumi/pulumi-awsx/sdk/v2/go/awsx/lb"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

func getDefaultTags(ctx *pulumi.Context) pulumi.StringMap {
	return pulumi.StringMap{
		"Project": pulumi.String("ZZNZ Bio Profile"),
		"Purpose": pulumi.String("Production"),
	}
}

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		defaultTags := getDefaultTags(ctx)
		cfg := config.New(ctx, "")
		containerPort := 80
		if param := cfg.GetInt("containerPort"); param != 0 {
			containerPort = param
		}
		cpu := 512
		if param := cfg.GetInt("cpu"); param != 0 {
			cpu = param
		}
		memory := 128
		if param := cfg.GetInt("memory"); param != 0 {
			memory = param
		}

		vpc, err := ec2.NewVpc(ctx, "go-server-vpc-"+ctx.Stack(), &ec2.VpcArgs{
			Tags: defaultTags,
			NatGateways: &ec2.NatGatewayConfigurationArgs{
				Strategy: ec2.NatGatewayStrategyNone,
			},
			NumberOfAvailabilityZones: pulumi.IntRef(3),
		})

		// An ECS cluster to deploy into
		cluster, err := ecs.NewCluster(ctx, "cluster", &ecs.ClusterArgs{
			Tags: defaultTags,
		})
		if err != nil {
			return err
		}

		// An ALB to serve the container endpoint to the internet
		loadbalancer, err := lbx.NewApplicationLoadBalancer(ctx, "loadbalancer", &lbx.ApplicationLoadBalancerArgs{
			SubnetIds: vpc.PublicSubnetIds,
			Tags:      defaultTags,
		})
		if err != nil {
			return err
		}

		// An ECR repository to store our application's container image
		repo, err := ecrx.NewRepository(ctx, "repo", &ecrx.RepositoryArgs{
			ForceDelete: pulumi.Bool(true),
			Tags:        defaultTags,
		})
		if err != nil {
			return err
		}

		// Build and publish our application's container image from ./app to the ECR repository
		image, err := ecrx.NewImage(ctx, "image", &ecr.ImageArgs{
			RepositoryUrl: repo.Url,
			Context:       pulumi.String("./app"),
			Platform:      pulumi.String("linux/arm64"),
			Args: pulumi.StringMap{
				"build-arg": pulumi.String(fmt.Sprintf("PORT=%d", containerPort)),
			},
		})
		if err != nil {
			return err
		}

		// Deploy an ECS Service on Fargate to host the application container
		_, err = ecsx.NewFargateService(ctx, "service", &ecsx.FargateServiceArgs{
			Cluster:        cluster.Arn,
			AssignPublicIp: pulumi.Bool(true),
			TaskDefinitionArgs: &ecsx.FargateServiceTaskDefinitionArgs{
				Container: &ecsx.TaskDefinitionContainerDefinitionArgs{
					Name:      pulumi.String("app"),
					Image:     image.ImageUri,
					Cpu:       pulumi.Int(cpu),
					Memory:    pulumi.Int(memory),
					Essential: pulumi.Bool(true),
					PortMappings: ecsx.TaskDefinitionPortMappingArray{
						&ecsx.TaskDefinitionPortMappingArgs{
							ContainerPort: pulumi.Int(containerPort),
							HostPort:      pulumi.Int(containerPort),
							Protocol:      pulumi.String("tcp"),
							TargetGroup:   loadbalancer.DefaultTargetGroup,
						},
					},
				},
			},
			DesiredCount: pulumi.Int(1),
			Tags:         defaultTags,
		})
		if err != nil {
			return err
		}

		// The URL at which the container's HTTP endpoint will be available
		ctx.Export("url", pulumi.Sprintf("https://%s", loadbalancer.LoadBalancer.DnsName()))
		return nil
	})
}

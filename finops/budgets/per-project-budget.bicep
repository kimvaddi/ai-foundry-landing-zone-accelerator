// finops/budgets/per-project-budget.bicep — Per-project Azure Cost Mgmt budget
//
// Deploy at subscription scope. One module instance per project.

targetScope = 'subscription'

@description('Friendly project name (becomes part of the budget name).')
param projectName string

@description('Monthly budget in USD.')
@minValue(1)
param amountUsd int

@description('Email recipients of alert.')
param contactEmails array

@description('Resource group containing the project resources (used to filter cost).')
param projectResourceGroupName string

@description('Budget period start month in YYYY-MM. Defaults to current UTC month. Bicep only allows utcNow() as a parameter default, so it is exposed here.')
param startMonth string = utcNow('yyyy-MM')

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'bdg-${projectName}'
  properties: {
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: '${startMonth}-01'
    }
    amount: amountUsd
    category: 'Cost'
    filter: {
      dimensions: {
        name: 'ResourceGroupName'
        operator: 'In'
        values: [ projectResourceGroupName ]
      }
    }
    notifications: {
      actualEighty: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: contactEmails
      }
      forecastedHundred: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: contactEmails
      }
    }
  }
}

output budgetId string = budget.id

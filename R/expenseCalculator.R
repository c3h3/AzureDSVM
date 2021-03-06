#' @title Get data consumption of an Azure subscription for a time period. Aggregation method can be either daily based or hourly based.
#' 
#' @note Formats of start time point and end time point follow ISO 8601 standard. Say if one would like to calculate data consumption between Feb 21, 2017 to Feb 25, 2017, with an aggregation granularity of "daily based", the inputs should be "2017-02-21 00:00:00" and "2017-02-25 00:00:00", for start time point and end time point, respectively. If the aggregation granularity is hourly based, the inputs can be "2017-02-21 01:00:00" and "2017-02-21 02:00:00", for start and end time point, respectively. NOTE by default the Azure data consumption API does not allow an aggregation granularity that is finer than an hour. In the case of "hourly based" granularity, if the time difference between start and end time point is less than an hour, data consumption will still be calculated hourly based with end time postponed. For example, if the start time point and end time point are "2017-02-21 00:00:00" and "2017-02-21 00:45:00", the actual returned results are are data consumption in the interval of "2017-02-21 00:00:00" and "2017-02-21 01:00:00". However this calculation is merely for retrieving the information of an existing DSVM instance (e.g., meterId) with which the pricing rate is multiplied by to obtain the overall expense. Time zone of all time inputs are synchronized to UTC.
#' 
#' @param context AzureSMR context object.
#' 
#' @param instance Instance of Azure DSVM name that one would like to check expense. 
#' 
#' @param time.start Start time.
#' 
#' @param time.end End time.
#' 
#' @param granularity Aggregation granularity. Can be either "Daily" or "Hourly".
#' 
#' @export
dataConsumption <- function(context,
                            instance,
                            time.start,
                            time.end,
                            granularity="Hourly"
) {
  # renew token if it expires.

  azureCheckToken(context)

  # preconditions here...

  if(missing(context) || !is.azureActiveContext(context))
    stop("Please specify a valid AzureSMR context.")

  if(missing(instance))
    stop("Please give instance name for retrieving records of data consumption.")

  if(missing(time.start))
    stop("Please specify a starting time point in YYYY-MM-DD HH:MM:SS format.")

  if(missing(time.end))
    stop("Please specify an ending time point in YYYY-MM-DD HH:MM:SS format.")

  ds <- try(as.POSIXlt(time.start, format= "%Y-%m-%d %H:%M:%S", tz="UTC"))
  de <- try(as.POSIXlt(time.end, format= "%Y-%m-%d %H:%M:%S", tz="UTC"))

  if (class(ds) == "try-error" ||
     is.na(ds) ||
     class(de) == "try-error" ||
     is.na(de))
    stop("Input date format should be YYYY-MM-DD HH:MM:SS.")

  time.start <- ds
  time.end <- de

  if (time.start >= time.end)
    stop("End time is no later than start time!")

  lubridate::minute(time.start) <- 0
  lubridate::second(time.start) <- 0
  lubridate::minute(time.end)   <- 0
  lubridate::second(time.end)   <- 0

  if (granularity == "Daily") {

    # time.start and time.end should be some day at midnight.

    lubridate::hour(time.start) <- 0
    lubridate::hour(time.end) <- 0

  }

  # If the computation time is less than a hour, time.end will be incremented by an hour to get the total cost within an hour aggregated from time.start. However, only the consumption on computation is considered in the returned data, and the computation consumption will then be replaced with the actual time.end - time.start.

  # NOTE: estimation of cost in this case is rough though, it captures the major component of total cost, which originates from running an Azure instance. Other than computation cost, there are also cost on activities such as data transfer, software library license, etc. This is not included in the approximation here until a solid method for capturing those consumption data is found. Data ingress does not generate cost, but data egress does. Usually the occurrence of data transfer is not that frequent as computation, and pricing rates for data transfer is also less than computation (e.g., price rate of "data transfer in" is ~ 40% of that of computation on an A3 virtual machine).

  # TODO: inlude other types of cost for jobs that take less than an hour.

  if (as.numeric(time.end - time.start) == 0) {
    writeLines("Difference between time.start and time.end is less than the aggregation granularity. Cost is estimated solely on computation running time.")

    # increment time.end by one hour.

    time.end <- time.end + 3600
  }

  # reformat time variables to make them compatible with API call.

  START <- URLencode(paste(as.Date(time.start), "T",
                           sprintf("%02d", lubridate::hour(time.start)), ":", sprintf("%02d", lubridate::minute(time.start)), ":", sprintf("%02d", second(time.start)), "+",
                           "00:00",
                           sep=""),
                     reserved=TRUE)

  END <- URLencode(paste(as.Date(time.end), "T",
                           sprintf("%02d", lubridate::hour(time.end)), ":", sprintf("%02d", lubridate::minute(time.end)), ":", sprintf("%02d", second(time.end)), "+",
                           "00:00",
                           sep=""),
                     reserved=TRUE)

  URL <-
    sprintf("https://management.azure.com/subscriptions/%s/providers/Microsoft.Commerce/UsageAggregates?api-version=%s&reportedStartTime=%s&reportedEndTime=%s&aggregationgranularity=%s&showDetails=%s",
            context$subscriptionID,
            "2015-06-01-preview",
            START,
            END,
            granularity,
            "false"
    )

  r <- GET(URL,
           add_headers(.headers=c("Host"="management.azure.com", "Authorization"=context$Token, "Content-Type"="application/json")))

  if (r$status_code == 200) {
    rl <- content(r,"text",encoding="UTF-8")
    df <- fromJSON(rl)
  } else {

    # for debug use.

    print(content(r, encoding="UTF-8"))

    stop(sprintf("Fail! The return code is %s", r$status_code))
  }

  df_use <-
    df$value$properties %>%
    select(-infoFields)

  inst_data <-
    df$value$properties$instanceData %>%
    lapply(., fromJSON)

  # retrieve results that match instance name.

  instance_detect <- function(inst_data) {
    return(basename(inst_data$Microsoft.Resources$resourceUri) == instance)
  }

  index_instance <- which(unlist(lapply(inst_data, instance_detect)))

  if(!missing(instance)) {
    if(length(index_instance) == 0)
      stop("No data consumption records found for the instance during the given period.")
    df_use <- df_use[index_instance, ]
  } else if(missing(instance)) {
    if(length(index_resource) == 0)
      stop("No data consumption records found for the resource group during the given period.")
    df_use <- df_use[index_resource, ]
  }

  # if time difference is less than one hour. Only return one row of computation consumption whose value is the time difference.

  # time.end <- time.end - 3600

  if(as.numeric(time.end - time.start) == 0) {

    time_diff <- as.numeric(de - ds) / 3600

    df_use %<>%
      select(usageStartTime,
             usageEndTime,
             meterName,
             meterCategory,
             meterSubCategory,
             unit,
             meterId,
             quantity,
             meterRegion) %>%
      filter(meterName == "Compute Hours") %>%
      filter(row_number() == 1) %>%
      mutate(quantity = time_diff) %>%
      mutate(usageStartTime = as.POSIXct(usageStartTime)) %>%
      mutate(usageEndTime = as.POSIXct(usageEndTime)) 

    writeLines(sprintf("The data consumption for %s between %s and %s is",
                       instance,
                       as.character(time.start),
                       as.character(time.end)))
    return(df_use)

  } else {

    # NOTE the maximum number of records returned from API is limited to 1000.

    if (nrow(df_use) == 1000 && max(as.POSIXct(df_use$usageEndTime)) < as.POSIXct(END)) {
      warning(sprintf("The number of records in the specified time period %s to %s exceeds the limit that can be returned from API call. Consumption information is truncated. Please use a small period instead.", START, END))
    }

    df_use %<>%
      select(usageStartTime,
             usageEndTime,
             meterName,
             meterCategory,
             meterSubCategory,
             unit,
             meterId,
             quantity,
             meterRegion) %>%
      mutate(usageStartTime = as.POSIXct(usageStartTime)) %>%
      mutate(usageEndTime = as.POSIXct(usageEndTime)) 

    writeLines(sprintf("The data consumption for %s between %s and %s is",
                       instance,
                       as.character(time.start),
                       as.character(time.end)))

    df_use
  }
}

#' @title Get pricing details of resources under a subscription.
#' 
#' @param context - Azure Context Object.
#' 
#' @param currency Currency in which price rating is measured.
#' 
#' @param locale Locality information of subscription.
#' 
#' @param offerId Offer ID of the subscription. Detailed information can be found at https://azure.microsoft.com/en-us/support/legal/offer-details/
#' 
#' @param region region information about the subscription.
#' 
#' @export
pricingRates <- function(context,
                         currency,
                         locale,
                         offerId,
                         region
) {
  # renew token if it expires.

  azureCheckToken(context)

  # preconditions.

  if(missing(currency))
    stop("Error: please provide currency information.")

  if(missing(locale))
    stop("Error: please provide locale information.")

  if(missing(offerId))
    stop("Error: please provide offer ID.")

  if(missing(region))
    stop("Error: please provide region information.")

  url <- paste(
    "https://management.azure.com/subscriptions/", context$subscriptionID,
    "/providers/Microsoft.Commerce/RateCard?api-version=2016-08-31-preview&$filter=",
    "OfferDurableId eq '", offerId, "'",
    " and Currency eq '", currency, "'",
    " and Locale eq '", locale, "'",
    " and RegionInfo eq '", region, "'",
    sep="")

  url <- URLencode(url)

  # # for debug purpose.
  #
  # cat(url)

  r <- GET(url, add_headers(.headers=c(Authorization=context$Token, "Content-Type"="application/json")))

  rl <- fromJSON(content(r, "text", encoding="UTF-8"), simplifyDataFrame=TRUE)

  df_meter <- rl$Meters
  df_meter$MeterRate <- rl$Meters$MeterRates$`0`

  # an irresponsible drop of MeterRates and MeterTags. Will add them back after having a better handle of them.

  df_meter <- subset(df_meter, select=-MeterRates)
  df_meter <- subset(df_meter, select=-MeterTags)

  return(df_meter)
}

#' @title Calculate cost of using a specific instance of Azure for certain period.
#' 
#' @param context AzureSMR context.
#' 
#' @param instance Instance of Azure instance that one would like to check expense. No matter whether resource group is given or not, if a instance of instance is given, data consumption of that instance is returned.
#' 
#' @param time.start Start time.
#' 
#' @param time.end End time.
#' 
#' @param granularity Aggregation granularity. Can be either "Daily" or "Hourly".
#' 
#' @param currency Currency in which price rating is measured.
#' 
#' @param locale Locality information of subscription.
#' 
#' @param offerId Offer ID of the subscription. Detailed information can be found at https://azure.microsoft.com/en-us/support/legal/offer-details/
#' 
#' @param region region information about the subscription.
#' 
#' @return Total cost measured in the given currency of the specified Azure instance in the period.
#' 
#' @note Note if difference between \code{time.start} and \code{time.end} is less than the finest granularity, e.g., "Hourly" (we notice this is a usual case when one needs to be aware of the charges of a job that takes less than an hour), the expense will be estimated based solely on computation hour. That is, the total expense is the multiplication of computation hour and pricing rate of the DSVM instance.
#' 
#' @export
expenseCalculator <- function(context,
                              instance,
                              time.start,
                              time.end,
                              granularity,
                              currency,
                              locale,
                              offerId,
                              region) {
  df_use <-
    dataConsumption(context,
                    instance=instance,
                    time.start=time.start,
                    time.end=time.end,
                    granularity=granularity) %>%
    select(meterId,
           meterSubCategory,
           usageStartTime,
           usageEndTime,
           quantity)

  df_used_data <-
    group_by(df_use, meterId) %>%
    arrange(usageStartTime, usageEndTime) %>%
    summarise(usageStartDate=as.Date(min(usageStartTime), tz=Sys.timezone()),
              usageEndDate=as.Date(max(usageEndTime), tz=Sys.timezone()),
              totalQuantity=sum(quantity)) %>%
    ungroup()

  # use meterId to find pricing rates and then calculate total cost.

  df_rates <- pricingRates(context,
                           currency=currency,
                           locale=locale,
                           region=region,
                           offerId=offerId)

  meter_list <- df_used_data$meterId

  df_used_rates <-
    filter(df_rates, MeterId %in% meter_list) %>%
    rename(meterId=MeterId)
  
  df_cost <-
    left_join(df_used_data, df_used_rates, by="meterId") %>%
    mutate(Cost=totalQuantity * MeterRate) %>%
    select(-IncludedQuantity, -EffectiveDate, -MeterStatus, -usageStartDate, -usageEndDate, -meterId, -MeterRegion) %>%
    na.omit()
  
  # reorder columns.
  
  df_cost <- df_cost[, c(3, 2, 4, 1, 5, 6, 7)]

  df_cost
}

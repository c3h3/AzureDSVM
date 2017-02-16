#' @title Deploy a new Data Science Virtual Machine (DSVM).
#'
#' @param context Authentication context of AzureSMR encapsulating the
#'   TID, CID, and key obtained from Azure Actrive Directory.
#' @param resource.group The Azure resource group where the DSVM is
#'   created.
#' @param location Location of the data centre to host the DSVM.
#' @param name Name of the DSVM.  Lowercase characters or numbers
#'   only. Special characters are not permitted.
#' @param username User name of the DSVM. It should be different from
#'   `name`.
#' @param size Size of the DSVM. The default is "Standard_D1_v2". All
#'   available sizes can be obtained by function `getVMSizes`.
#' @param os Operating system of DSVM. Permitted values are "Linux"
#'   and "Windows" for Linux based and Windows based operating
#'   systems, respectively.
#' @param authen Either "Key" or "Password", meaning public-key based
#'   or password based authentication, respectively. Note Windows DSVM
#'   by default uses password based authentication and this argument
#'   can be left unset.
#' @param pubkey Public key for the DSVM. Only applicable for
#'   public-key based authentication of Linux based DSVM.
#' @param password Pass word for the DSVM.
#' @param dns DNS label for the VM address. The URL for accessing the
#'   deployed DSVM will be "<dns_label>.<location>.cloudapp.azure.com
#' @param mode Mode of virtual machine deployment. Default is "Sync".
#'
#' @export
deployDSVM <- function(context,
                       resource.group,
                       location,
                       name,
                       username,
                       size="Standard_D1_v2",
                       os,
                       authen="",
                       pubkey="",
                       password="",
                       dns=paste0(name, "dns"),
                       mode="Sync")
{
  # check if required arguments are present.

  if(missing(context))
    stop("Please specify a context (contains TID, CID, KEY).")

  if(missing(resource.group))
    stop("Please specify an Azure resouce group.")

  if(missing(location))
    stop("Please specify a data centre location.")

  if(missing(name))
    stop("Please specify a virtual machine name.")

  if(missing(username))
    stop("Please specify a virtual machine user name.")

  if(missing(os))
    stop("Please specify a virtual machine OS.")

  if(os == "Linux" && missing(authen))
    stop("Please specify an authentication method for Linux DSVM.")

  if(os == "Windows" && missing(password))
    stop("Please specify a password for Windows DSVM.")

  if(authen == "Key" && missing(pubkey))
    stop("Please specify a public key.")

  if(authen == "Password" && missing(password))
    stop("Please specify a password.")

  # Other preconditions.

  # check if AzureSMR context is valid.

  if(!is.azureActiveContext(context))
    stop("Please use a valid AzureSMR context.")

  # check if resource group exists.

  rg_exist <-
    context %>%
    azureListRG() %>%
    filter(name == RG) %>%
    select(name, location) %>%
    nrow() %>%
    equals(0) %>%
    not()

  if(!rg_exist)
    stop("The specified resource group does not exist in the current region.")

  # Check if location is available.

  # if(location %in% c("location_code_1", ...))

  # Check if vm size exists.

#  if(!(size %in% getVMSizes()$Sizes))
#    stop("Unknown size - see getVMSizes() for allowed options.")

  # Incorrect naming of a vm may lead to an unsuccessful deployment of
  # the DSVM - normally it returns a 400 error from REST call. Check
  # the name here to ensure it is valid.

  if(length(name) > 15)
    stop("Name of virtual machine is too long.")

  if(grepl("[[:upper:]]|[[:punct:]]", name))
    stop("Name of virtual machine is not valid - only lowercase and digits permitted.")

  # check if password is valid.

  # if(!grepl("^(?=.*[[A-Za-z]])(?=.*\\d)(?=.*[[$@$!%*#?&]])[[A-Za-z\\d$@$!%*#?&]]{8,}$", password))
  #   stop("Password not valid - minimum 8 characters with at least one digit and one special character.")

  # Load template and parameter JSON files for deployment

  if(os == "Windows") {
    temp_path <- system.file("etc", "template_windows.json", package="AzureDSR")
    para_path <- system.file("etc", "parameter_windows.json", package="AzureDSR")
  } else if(os == "Linux") {
    if(authen == "Key") {
      temp_path <- system.file("etc", "template_linux_key.json", package="AzureDSR")
      para_path <- system.file("etc", "parameter_linux_key.json", package="AzureDSR")
    } else if(authen == "Password") {
      temp_path <- system.file("etc", "template_linux.json", package="AzureDSR")
      para_path <- system.file("etc", "parameter_linux.json", package="AzureDSR")
    } else {
      stop("Please specific a valid authentication method, i.e., either 'Key' for public key based or 'Password' for password based, for Linux OS based DSVM")
    }
  } else {
    stop("Please specify a valid OS type, i.e., either 'Windows' or 'Linux'.")
  }

  # Update the parameter JSON with the virtual machine name.

  param <-
    readLines(para_path) %>%
    gsub("<LOCATION>", location, .) %>%
    gsub("<DEFAULT>", name, .) %>%
    gsub("<USER>", username, .) %>%
    gsub("<VMSIZE>", size, .) %>%
    gsub("<PWD>", password, .) %>%
    gsub("<PUBKEY>", pubkey, .) %>%
    paste0(collapse="")

  # Update the template JSON with the appropriate parameters.

  templ <-
    readLines(temp_path) %>%
    gsub("<DNS_LABEL>", dns, .) %>%
    paste0(collapse="")

  dname <- paste0(name, "_dpl")

  AzureSMR::azureDeployTemplate(context,
                                deplname=dname,
                                templateJSON=templ,
                                paramJSON=param,
                                resourceGroup=resource.group,
                                mode=mode)

  fqdn <- paste0(name, ".", location, ".cloudapp.azure.com")

  if (tolower(mode) == "sync")
    attr(fqdn, "ip") <-
      system(paste("dig", fqdn, "+short"), intern=TRUE) # Get from the VM meta data?

  return(fqdn)
}
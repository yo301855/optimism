/*
Copyright 2019-present OmiseGO Pte Ltd

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

import React,{useState,useEffect,useCallback} from 'react'
import { useSelector, useDispatch, batch } from 'react-redux'

import { isEqual, orderBy } from 'lodash'

//Selectors
import { selectlayer2Balance, selectlayer1Balance } from 'selectors/balanceSelector'
import { selectTransactions } from 'selectors/transactionSelector'

import ListAccount from 'components/listAccount/listAccount'

import networkService from 'services/networkService'

import * as S from './Account.styles'

import { selectTokens } from 'selectors/tokenSelector'
import { selectLoading } from 'selectors/loadingSelector'

import PageHeader from 'components/pageHeader/PageHeader'
import { Box, Grid, Tab, Tabs, Typography, useMediaQuery } from '@material-ui/core'
import { fetchLookUpPrice, fetchTransactions } from 'actions/networkAction'
import { selectNetwork } from 'selectors/setupSelector'
import { useTheme } from '@emotion/react'
import { tableHeadList } from './tableHeadList'
import TabPanel from 'components/tabs/TabPanel'
import Drink from '../../images/backgrounds/drink.png'
import NetworkSwitcherIcon from 'components/icons/NetworkSwitcherIcon'

import PendingTransaction from './PendingTransaction'
import useInterval from 'util/useInterval'

import { POLL_INTERVAL } from 'util/constant'

function Account () {

  const networkLayer = networkService.L1orL2 === 'L1' ? 'L1' : 'L2'
  
  const dispatch = useDispatch()
  
  const [activeTab, setActiveTab] = useState(networkLayer === 'L1' ? 0 : 1)

  const childBalance = useSelector(selectlayer2Balance, isEqual)
  const rootBalance = useSelector(selectlayer1Balance, isEqual)

  const tokenList = useSelector(selectTokens)

  const network = useSelector(selectNetwork())

  const depositLoading = useSelector(selectLoading(['DEPOSIT/CREATE']))
  const exitLoading    = useSelector(selectLoading(['EXIT/CREATE']))

  const disabled = depositLoading || exitLoading

  //console.log("disabled:",disabled)
  //console.log("loading:",loading)

  const getLookupPrice = useCallback(()=>{
    const symbolList = Object.values(tokenList).map((i)=> {
      if(i.symbolL1 === 'ETH') {
        return 'ethereum'
      } else if(i.symbolL1 === 'OMG') {
        return 'omg'
      } else {
        return i.symbolL1.toLowerCase()
      }
    })
    dispatch(fetchLookUpPrice(symbolList))
  },[tokenList, dispatch])

  const unorderedTransactions = useSelector(selectTransactions, isEqual)

  const orderedTransactions = orderBy(unorderedTransactions, i => i.timeStamp, 'desc')

  const pendingL1 = orderedTransactions.filter((i) => {
      if (i.chain === 'L1pending' && //use the custom API watcher for fast data on pending L1->L2 TXs
          i.crossDomainMessage &&
          i.crossDomainMessage.crossDomainMessage === 1 &&
          i.crossDomainMessage.crossDomainMessageFinalize === 0 &&
          i.action.status === "pending"
      ) {
          return true
      }
      return false
  })

  const pendingL2 = orderedTransactions.filter((i) => {
      if (i.chain === 'L2' &&
          i.crossDomainMessage &&
          i.crossDomainMessage.crossDomainMessage === 1 &&
          i.crossDomainMessage.crossDomainMessageFinalize === 0 &&
          i.action.status === "pending"
      ) {
          return true
      }
      return false
  })

  const pending = [
    ...pendingL1,
    ...pendingL2
  ]

  useEffect(()=>{
    getLookupPrice()
  },[childBalance, rootBalance, getLookupPrice])

  useInterval(() => {
    batch(() => {
      dispatch(fetchTransactions())
    })
  }, POLL_INTERVAL)

  const theme = useTheme()
  const isMobile = useMediaQuery(theme.breakpoints.down('md'))

  const handleChange = (event, newValue) => {
    setActiveTab(newValue)
  }

  const ActiveItem = ({active}) => (
    <Box display="flex" sx={{ justifyContent: 'center', gap: 1 }}>
      <NetworkSwitcherIcon active={active} /> <Typography variant="overline">Active</Typography>
    </Box>
  )

  // const mobileL1 = network + ' L1'
  // const mobileL2 = 'BOBA L2 ' + network

  let label_L1 = 'Ethereum L1'
  if(network === 'rinkeby') label_L1 = 'Rinkeby L1'

  let label_L2 = 'Boba L2'
  if(network === 'rinkeby') label_L2 = 'Boba Rinkeby L2'

  const L1Column = () => (
    <S.AccountWrapper >

      {!isMobile ? (
        <S.WrapperHeading>
          <Typography variant="h3" sx={{opacity: networkLayer === 'L1' ? "1.0" : "0.2", fontWeight: "700"}}>{label_L1}</Typography>
          {/* <SearchIcon color={theme.palette.secondary.main}/> */}
          {networkLayer === 'L1' ? <ActiveItem active={true} /> : null}
        </S.WrapperHeading>
        ) : (null)
      }

      <S.TableHeading>
        {tableHeadList.map((item) => {
          return (
            <S.TableHeadingItem key={item.label} variant="body2" component="div" sx={{opacity: networkLayer === 'L1' ? "1.0" : "0.2"}}>
              {item.label}
            </S.TableHeadingItem>
          )
        })}
      </S.TableHeading>

      <Box>
        {rootBalance.map((i, index) => {
          return (
            <ListAccount
              key={i.currency}
              token={i}
              chain={'L1'}
              networkLayer={networkLayer}
              disabled={disabled}
            />
          )
        })}
      </Box>
    </S.AccountWrapper>
  )

  const L2Column = () => (
    <S.AccountWrapper>
      {!isMobile ? (
        <S.WrapperHeading>
          <Typography variant="h3" sx={{opacity: networkLayer === 'L2' ? "1.0" : "0.4", fontWeight: "700"}}>{label_L2}</Typography>
          {/* <SearchIcon color={theme.palette.secondary.main}/> */}
          {networkLayer === 'L2' ? <ActiveItem active={true} /> : null}
        </S.WrapperHeading>
        ) : (null)
      }

      <S.TableHeading sx={{opacity: networkLayer === 'L2' ? "1.0" : "0.4"}}>
        {tableHeadList.map((item) => {
          return (
            <S.TableHeadingItem key={item.label} variant="body2" component="div">{item.label}</S.TableHeadingItem>
          )
        })}
      </S.TableHeading>

      <Box>
        {childBalance.map((i, index) => {
          return (
            <ListAccount
              key={i.currency}
              token={i}
              chain={'L2'}
              networkLayer={networkLayer}
              disabled={disabled}
            />
          )
        })}
      </Box>
    </S.AccountWrapper>
  );

  return (
    <>
      <PageHeader title="Wallet"/>

      <S.CardTag>
        <S.CardContentTag>
          <S.CardInfo>Boba Balances</S.CardInfo>
          {(network === 'mainnet') &&
          <>
          <Typography variant="body2">
             You are using Mainnet.<br/>
             WARNING: the mainnet smart contracts are not fully audited and funds may be at risk.<br/>
             Please be cautious when using Mainnet.
          </Typography>
          <Typography variant="body2" style={{color: 'yellow',fontSize: '1.0em'}}>
             NOTICE NOTICE NOTICE<br/>
             Boba mainnet will be upgraded to v2 on October 28 at 00:00 UTC. Services will be offline during the regenesis, 
             which is expected to take less than 12 hours. 
             As part of the transition to v2, the classical 7-day bridge from L2 to L1 HAS NOW BEEN PAUSED, and will resume post-regenesis.
             The fast bridges will remain active, except during the regenesis itself.  
          </Typography>
          </>
          }
        </S.CardContentTag>
        <Box sx={{flex: 3}}>
          <S.ContentGlass>
            <img src={Drink} href="#" width={135} alt="Boba Drink"/>
          </S.ContentGlass>
        </Box>
      </S.CardTag>
      
      {disabled &&
        <S.LayerAlert style={{border: 'solid 1px yellow'}}>
          <S.AlertInfo>
            <S.AlertText
              variant="body2"
              component="p"
            >
              Transaction in progress - please be patient
            </S.AlertText>
          </S.AlertInfo>
        </S.LayerAlert>
      }

      {pending.length > 0 &&
        <Grid sx={{margin: '10px 0px'}}>
          <Grid item xs={12}>
            <PendingTransaction />
          </Grid>
        </Grid>
      }
      {isMobile ? (
        <>
          <Tabs value={activeTab} onChange={handleChange} sx={{color: '#fff', fontWeight: 700, my: 2}}>
            <Tab label={label_L1} />
            <Tab label={label_L2} />
          </Tabs>
          <TabPanel value={activeTab} index={0}>
            <L1Column />
          </TabPanel>
          <TabPanel value={activeTab} index={1}>
            <L2Column />
          </TabPanel>
        </>
      ) : (
        <Grid container spacing={2} >
          <Grid item xs={12} md={6} >
            <L1Column />
          </Grid>

          <Grid item xs={12} md={6}>
            <L2Column />
          </Grid>
        </Grid>
      )}
    </>
  );

}

export default React.memo(Account);

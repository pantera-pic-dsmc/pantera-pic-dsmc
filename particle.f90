! This module contains the structure of particles and useful functions
! for handling them

MODULE particle

   ! Define particle type and arrays !!!!!!!!!!!!!!!!!!!!!!!!!!!!
 
   TYPE PARTICLE_DATA_STRUCTURE
      REAL(KIND=8) :: X, Y, Z        ! position
      REAL(KIND=8) :: VX, VY, VZ, EI ! velocities and internal energy
      REAL(KIND=8) :: DTRIM          ! Remaining time for advection
      INTEGER      :: IC             ! Cell index 
      INTEGER      :: S_ID           ! Species ID
   END TYPE PARTICLE_DATA_STRUCTURE
 
   CONTAINS

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE INIT_PARTICLE -> initializes a particle, given required fields !!!
   ! By using this subroutine, the one does not have to modify everything if a !!!
   ! field is added/removed to/from the particle type.                         !!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE INIT_PARTICLE(X, Y, Z, VX, VY, VZ, EI, S_ID, IC, DTRIM, particlept)

      IMPLICIT NONE
      
      REAL(KIND=8), INTENT(IN) :: X, Y, Z, VX, VY, VZ, EI, DTRIM
      INTEGER, INTENT(IN)      :: S_ID, IC

      TYPE(PARTICLE_DATA_STRUCTURE), INTENT(INOUT) :: particlept
     
      particlept%X    = X
      particlept%Y    = Y
      particlept%Z    = Z
 
      particlept%VX   = VX
      particlept%VY   = VY
      particlept%VZ   = VZ

      particlept%EI   = EI
 
      particlept%S_ID = S_ID 
      particlept%IC   = IC  

      particlept%DTRIM = DTRIM

   END SUBROUTINE INIT_PARTICLE

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE ADD_PARTICLE_ARRAY -> adds a particle to "particles" array     !!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE ADD_PARTICLE_ARRAY(particleNOW, NP, particlesARRAY)

      ! This subroutine adds a particle to the particlesARRAY, which contains 
      ! NP particles.
      ! "particlesARRAY" can have a size larger than NP, so that it is not necessary
      ! to change its size every time one more particle is added.
      ! 
      ! For copying a particle, we first check that there is space. If the space is 
      ! over, the vector is enlarged 5 times, and the particle is copied>
      ! 
      ! 1) Increase NP (global variable)
      ! 2) Check if there is enough space in the vector
      !   YES? -> Add particle at new position NP
      !   NO?  -> Make a backup copy of it, make it 5 times larger (reallocate) and then do it.

      IMPLICIT NONE

      TYPE(PARTICLE_DATA_STRUCTURE), INTENT(IN)                                :: particleNOW
      TYPE(PARTICLE_DATA_STRUCTURE), DIMENSION(:), ALLOCATABLE, INTENT(INOUT)  :: particlesARRAY
      INTEGER, INTENT(INOUT) :: NP ! Number of particles in particlesARRAY (which is /= of its size!)

      TYPE(PARTICLE_DATA_STRUCTURE), DIMENSION(:), ALLOCATABLE :: COPYARRAY

      NP = NP + 1 ! Increase number of particles in array

      IF ( NP > SIZE(particlesARRAY) ) THEN  ! Array too small

        ! Make backup copy of particles array
        ALLOCATE(COPYARRAY(NP-1))
        COPYARRAY = particlesARRAY

        ! Reallocate particles array to 5 times its size
        DEALLOCATE(particlesARRAY)
        ALLOCATE(particlesARRAY(5*NP))

        ! Re-copy the elements 
        particlesARRAY(1:NP-1) = COPYARRAY(1:NP-1)

        DEALLOCATE(COPYARRAY)
      END IF

      ! Add particle to array
      particlesARRAY(NP) = particleNOW

   END SUBROUTINE ADD_PARTICLE_ARRAY

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTOINE REMOVE_PARTICLE_ARRAY -> Removes a particle from the array !!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE REMOVE_PARTICLE_ARRAY(ID_REMOVE, particlesARRAY, NP_ARRAY)

      ! This subroutine removes a particle from the particlesARRAY, whose length is NP_ARRAY.
      ! The last particle in the array is copied in place of the particle to be removed "ID_REMOVE".
      ! Then, NP_ARRAY is decremented by 1.

      IMPLICIT NONE

      INTEGER, INTENT(IN)    :: ID_REMOVE
      INTEGER, INTENT(INOUT) :: NP_ARRAY
      TYPE(PARTICLE_DATA_STRUCTURE), DIMENSION(:), INTENT(INOUT)  :: particlesARRAY
 
      ! First, copy the last particle in the place of the particle to be removed
      CALL INIT_PARTICLE(particlesARRAY(NP_ARRAY)%X,  particlesARRAY(NP_ARRAY)%Y,    particlesARRAY(NP_ARRAY)%Z,  &
                         particlesARRAY(NP_ARRAY)%VX, particlesARRAY(NP_ARRAY)%VY,   particlesARRAY(NP_ARRAY)%VZ, &
                         particlesARRAY(NP_ARRAY)%EI, particlesARRAY(NP_ARRAY)%S_ID, particlesARRAY(NP_ARRAY)%IC, &
                         particlesARRAY(NP_ARRAY)%DTRIM, particlesARRAY(ID_REMOVE))

      ! Then put the last place to zeros and decrement counter
      CALL INIT_PARTICLE(0.d0,0.d0,0.d0,0.d0,0.d0,0.d0,0.d0,-1,-1, 0.d0, particlesARRAY(NP_ARRAY)) ! Zero

      NP_ARRAY = NP_ARRAY - 1

   END SUBROUTINE REMOVE_PARTICLE_ARRAY


! USELESS! JUST DO:  part_new(ii) = part_old(ii)   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! USELESS! JUST DO:  part_new(ii) = part_old(ii)   ! SUBROUTINE COPY_PARTICLE -> copies a particle from PARTICLE_ORIG to PARTICLE_DEST !!!
! USELESS! JUST DO:  part_new(ii) = part_old(ii)   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! USELESS! JUST DO:  part_new(ii) = part_old(ii)
! USELESS! JUST DO:  part_new(ii) = part_old(ii)   SUBROUTINE COPY_PARTICLE(PARTICLE_ORIG, PARTICLE_DEST)
! USELESS! JUST DO:  part_new(ii) = part_old(ii)
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      IMPLICIT NONE
! USELESS! JUST DO:  part_new(ii) = part_old(ii)
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      TYPE(PARTICLE_DATA_STRUCTURE), INTENT(IN)  :: PARTICLE_ORIG
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      TYPE(PARTICLE_DATA_STRUCTURE), INTENT(OUT) :: PARTICLE_DEST
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%X    = PARTICLE_ORIG%X
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%Y    = PARTICLE_ORIG%Y
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%Z    = PARTICLE_ORIG%Z
! USELESS! JUST DO:  part_new(ii) = part_old(ii) 
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%VX   = PARTICLE_ORIG%VX
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%VY   = PARTICLE_ORIG%VY
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%VZ   = PARTICLE_ORIG%VZ
! USELESS! JUST DO:  part_new(ii) = part_old(ii)
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%EI   = PARTICLE_ORIG%EI
! USELESS! JUST DO:  part_new(ii) = part_old(ii) 
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%S_ID = PARTICLE_ORIG%S_ID 
! USELESS! JUST DO:  part_new(ii) = part_old(ii)      PARTICLE_DEST%IC   = PARTICLE_ORIG%IC  
! USELESS! JUST DO:  part_new(ii) = part_old(ii) 
! USELESS! JUST DO:  part_new(ii) = part_old(ii)   END SUBROUTINE COPY_PARTICLE



END MODULE particle
